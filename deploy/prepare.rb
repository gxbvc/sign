# frozen_string_literal: true

# Test a built image before activation. Usage:
#   ruby deploy/prepare.rb COMMIT_SHA BACKUP_TARBALL_NAME
# The image ghcr.io/gxbvc/sign:COMMIT_SHA must already be pushed. This pulls it on the host with Kamal,
# then runs candidate mode A (empty temp volume) and mode B (copy of /opt/sign/backups/BACKUP_TARBALL_NAME).
require 'erb'
require 'yaml'
require 'json'
require_relative 'candidate'

module SignPrepare
  def self.run(version, backup)
    raise 'Invalid deployment version' unless version.match?(/\A[a-f0-9]{40}\z/)
    raise 'Backup tarball name required' if backup.to_s.empty?

    root = File.expand_path('..', __dir__)
    config = YAML.safe_load(ERB.new(File.read(File.join(root, 'config/deploy.yml'))).result)
    release = JSON.parse(File.read(File.join(__dir__, 'release.json')))
    host = config.fetch('servers').fetch('web').fetch('hosts').first
    image = "#{release.fetch('image')}:#{version}"
    # Logs in on the host and pulls the image. This does not touch the running app or the proxy.
    pulled = Dir.chdir(root) do
      system({ 'BUNDLE_GEMFILE' => File.join(__dir__, 'Gemfile') }, 'bundle', 'exec', 'kamal', 'build', 'pull', '--version', version)
    end
    raise 'Image pull on host failed' unless pulled

    id = "#{version[0, 12]}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
    begin
      SignCandidate.check_empty(host, image, config, id)
      SignCandidate.check_production_copy(host, image, config, id, backup)
    rescue StandardError
      warn 'Candidate failed. Production is unchanged.'
      raise
    end
    puts "PASS: candidate checks for #{image}"
  end
end

SignPrepare.run(ARGV.fetch(0), ARGV.fetch(1)) if $PROGRAM_NAME == __FILE__
