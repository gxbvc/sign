# frozen_string_literal: true

require 'shellwords'
require 'open3'

module SignCandidate
  def self.check(host, image, config, version)
    name = "sign-branding-check-#{version}"
    ssh = ['ssh', '-o', 'BatchMode=yes', "root@#{host}"]
    # No production volume, route, credentials, or outbound mail.
    command = ['docker', 'run', '--detach', '--rm', '--name', name,
               '--memory', '1g', '--workdir', '/app',
               '-e', 'SIGN_BRANDING_CHECK=true', '-e', 'APP_URL=http://localhost',
               '-e', 'SMTP_ADDRESS=127.0.0.1', '-e', 'SMTP_PORT=1',
               '-e', "SMTP_FROM=#{config.fetch('env').fetch('clear').fetch('SMTP_FROM')}"]
    config.fetch('volumes').drop(1).each { |volume| command.concat(['-v', volume]) }
    command << image
    output, status = Open3.capture2e(*ssh, command.shelljoin)
    raise "Candidate start failed: #{output}" unless status.success?
    begin
      healthy = false
      45.times do
        probe = ['docker', 'exec', name, 'ruby', '-rnet/http', '-e',
                 "exit(Net::HTTP.get_response(URI('http://127.0.0.1:3000/up')).code == '200' ? 0 : 1)"]
        _, health = Open3.capture2e(*ssh, probe.shelljoin)
        if health.success?
          healthy = true
          break
        end
        sleep 2
      end
      raise 'Candidate health check failed' unless healthy
      runner = ['docker', 'exec', name, 'bundle', 'exec', 'rails', 'runner', '/opt/gxb-sign/candidate_test.rb']
      raise 'Candidate Rails checks failed' unless system(*ssh, runner.shelljoin)
      assets = ['docker', 'exec', name, 'ruby', '-rnet/http', '-e',
                "%w[favicon.svg favicon-32x32.png apple-touch-icon.png icon-192.png icon-512.png og-image.png source.tar.gz].each { |f| r = Net::HTTP.get_response(URI('http://127.0.0.1:3000/gxb-sign/' + f)); abort(f) unless r.code == '200' }; puts 'PASS: public branding assets and source archive'"]
      raise 'Candidate asset checks failed' unless system(*ssh, assets.shelljoin)
    ensure
      system(*ssh, ['docker', 'stop', name].shelljoin, out: File::NULL)
    end
  end
end
