# frozen_string_literal: true

require 'shellwords'
require 'open3'

# Disposable candidates of our built image on the app host.
# Never mount sign_storage, never publish a port, never pass SMTP credentials.
# The container, its --internal network, and its temp volume are removed after the checks, including on failure.
module SignCandidate
  BACKUP_DIR = '/opt/sign/backups'
  BAILEY_SCHEMA = '20260819091500'
  ASSETS = %w[favicon.svg favicon-32x32.png apple-touch-icon.png icon-192.png icon-512.png og-image.png
              builder-branding-v1.css source.tar.gz].freeze

  module_function

  def ssh(host)
    ['ssh', '-o', 'BatchMode=yes', "root@#{host}"]
  end

  def remote(host, *command, allow_failure: false)
    output, status = Open3.capture2e(*ssh(host), command.shelljoin)
    raise "Remote command failed: #{command.first(3).join(' ')}: #{output.lines.last(5).join}" unless status.success? || allow_failure

    [output, status]
  end

  # Mode A: empty temp volume. Branding, metadata, assets, source archive, /up.
  # On an empty database /setup is open until the first account exists. candidate_test.rb creates a
  # throwaway account first and then asserts /setup redirects. Production has users, so its /setup stays locked
  # (mode B proves that on a copy of production data).
  def check_empty(host, image, config, id)
    with_candidate(host, "sign-candidate-#{id}-empty") do |names|
      start(host, image, config, names, 'SIGN_BRANDING_CHECK' => 'true')
      wait_healthy(host, names[:container])
      run_test(host, names[:container], '/opt/gxb-sign/candidate_test.rb')
      check_assets(host, names[:container])
      puts 'PASS: candidate A (empty volume)'
    end
  end

  # Mode B: a copy of production data from a backup tarball, without dump.rdb so no queued jobs run.
  def check_production_copy(host, image, config, id, backup)
    raise 'Invalid backup name' unless backup.match?(/\A[\w.-]+\.tar\.gz\z/)

    path = "#{BACKUP_DIR}/#{backup}"
    remote(host, 'test', '-f', path)
    with_candidate(host, "sign-candidate-#{id}-data") do |names|
      restore = 'tar -xzf /backups/archive.tar.gz -C /data/docuseal --exclude=./dump.rdb --exclude=dump.rdb && ' \
                'rm -f /data/docuseal/dump.rdb && test ! -e /data/docuseal/dump.rdb && test -f /data/docuseal/db.sqlite3'
      remote(host, 'docker', 'run', '--rm', '--network', 'none', '-v', "#{path}:/backups/archive.tar.gz:ro",
             '-v', "#{names[:volume]}:/data/docuseal", image, 'sh', '-c', restore)
      puts 'PASS: restored backup copy into a temp volume without dump.rdb'
      # Read the schema before any boot. RUN_MIGRATIONS=false keeps this read-only.
      output, = remote(host, 'docker', 'run', '--rm', '--network', 'none', '--workdir', '/app',
                       '-e', 'RUN_MIGRATIONS=false', '-e', 'SIGN_DATA_COPY_CHECK=true',
                       '-v', "#{names[:volume]}:/data/docuseal", image,
                       'bundle', 'exec', 'rails', 'runner', '/opt/gxb-sign/candidate_data_test.rb', 'before')
      puts output.lines.grep(/\A(PASS|INFO):/).join
      before = output[/^INFO: schema_version=(\d+)$/, 1] or raise 'Schema version before boot not found'
      raise "Unexpected schema before boot: #{before}" unless before == BAILEY_SCHEMA

      start(host, image, config, names, 'SIGN_DATA_COPY_CHECK' => 'true')
      wait_healthy(host, names[:container])
      run_test(host, names[:container], '/opt/gxb-sign/candidate_data_test.rb', 'after', before)
      check_assets(host, names[:container])
      puts 'PASS: candidate B (production data copy)'
    end
  end

  def with_candidate(host, name)
    candidate = { container: name, network: "#{name}-net", volume: "#{name}-data" }
    %i[container network volume].each do |kind|
      exists = remote(host, 'docker', kind.to_s, 'inspect', candidate[kind], allow_failure: true).last.success?
      raise "Candidate #{kind} #{candidate[kind]} already exists" if exists
    end
    # Only now do we own these names, so only now may the ensure block remove them.
    names = candidate
    remote(host, 'docker', 'network', 'create', '--internal', names[:network])
    remote(host, 'docker', 'volume', 'create', names[:volume])
    yield names
  ensure
    if names
      remote(host, 'docker', 'rm', '--force', '--volumes', names[:container], allow_failure: true)
      remote(host, 'docker', 'network', 'rm', names[:network], allow_failure: true)
      remote(host, 'docker', 'volume', 'rm', names[:volume], allow_failure: true)
      leftovers = %i[container network volume].select do |kind|
        remote(host, 'docker', kind.to_s, 'inspect', names[kind], allow_failure: true).last.success?
      end
      warn "WARNING: candidate cleanup left #{leftovers.join(', ')} for #{name}" if leftovers.any?
    end
  end

  def start(host, image, config, names, extra_env)
    env = { 'APP_URL' => 'http://localhost', 'SMTP_ADDRESS' => '127.0.0.1', 'SMTP_PORT' => '1',
            'SMTP_FROM' => config.fetch('env').fetch('clear').fetch('SMTP_FROM') }.merge(extra_env)
    command = ['docker', 'run', '--detach', '--name', names[:container], '--network', names[:network],
               '--memory', '1g', '--init', '--workdir', '/app', '-v', "#{names[:volume]}:/data/docuseal"]
    env.each { |key, value| command.push('-e', "#{key}=#{value}") }
    remote(host, *command, image)
  end

  def wait_healthy(host, container)
    probe = ['docker', 'exec', container, 'ruby', '-rnet/http', '-e',
             "exit(Net::HTTP.get_response(URI('http://127.0.0.1:3000/up')).code == '200' ? 0 : 1)"]
    60.times do
      return puts('PASS: /up') if remote(host, *probe, allow_failure: true).last.success?

      sleep 2
    end
    raise 'Candidate health check failed'
  end

  def run_test(host, container, script, *args)
    command = ['docker', 'exec', '-e', 'RUN_MIGRATIONS=false', container,
               'bundle', 'exec', 'rails', 'runner', script, *args]
    raise "Candidate Rails checks failed: #{script}" unless system(*ssh(host), command.shelljoin)
  end

  def check_assets(host, container)
    script = "%w[#{ASSETS.join(' ')}].each { |f| r = Net::HTTP.get_response(URI('http://127.0.0.1:3000/gxb-sign/' + f)); " \
             "abort(f) unless r.code == '200' }; " \
             "%w[favicon.svg favicon.ico].each { |f| abort(f) unless Net::HTTP.get_response(URI('http://127.0.0.1:3000/' + f)).code == '200' }; " \
             "puts 'PASS: public branding assets, root favicons, and source archive'"
    raise 'Candidate asset checks failed' unless system(*ssh(host), ['docker', 'exec', container, 'ruby', '-rnet/http', '-e', script].shelljoin)
  end
end
