# frozen_string_literal: true

require 'erb'
require 'yaml'
require 'json'
require 'tmpdir'
require 'shellwords'
require_relative 'package'
require_relative 'candidate'

module SignPrepare
  def self.run(version)
    raise 'Invalid deployment version' unless version.match?(/\A[a-zA-Z0-9.-]+\z/)
    ENV['SIGN_DEPLOY_VERSION'] = version
    root = File.expand_path('..', __dir__)
    config = YAML.safe_load(ERB.new(File.read(File.join(root, 'config/deploy.yml'))).result)
    release = JSON.parse(File.read(File.join(__dir__, 'release.json')))
    host = config.fetch('servers').fetch('web').fetch('hosts').first
    image = "#{release.fetch('image')}@#{release.fetch('digest')}"
    ssh = ['ssh', '-o', 'BatchMode=yes', "root@#{host}"]
    raise 'Pinned image pull failed' unless system(*ssh, ['docker', 'pull', image].shelljoin)
    remote = "/opt/sign/branding/#{version}"
    Dir.mktmpdir('sign-branding') do |tmp|
      directory = File.join(tmp, 'branding')
      SignPackage.build(directory)
      archive = File.join(tmp, 'branding.tar.gz')
      raise 'Branding archive failed' unless system({ 'COPYFILE_DISABLE' => '1' }, 'tar', '--no-xattrs', '-czf', archive, '-C', directory, '.')
      # Never overwrite files mounted by an existing running release.
      raise 'Branding release already exists' unless system(*ssh, "test ! -e #{remote} && mkdir -p #{remote}")
      begin
        raise 'Branding upload failed' unless system('scp', '-q', archive, "root@#{host}:#{remote}/upload.tar.gz")
        raise 'Branding extraction failed' unless system(*ssh, "tar -xzf #{remote}/upload.tar.gz -C #{remote} && rm #{remote}/upload.tar.gz")
        SignCandidate.check(host, image, config, version)
      rescue StandardError
        warn "Candidate failed. Production is unchanged; inspect #{remote} before retrying."
        raise
      end
    end
    puts "PASS: prepared and tested branding release #{version}"
  end
end

SignPrepare.run(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
