# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'

# Package public presentation files, plus corresponding source for AGPL users.
# No application build, credentials, database, or user uploads are included.
module SignPackage
  ROOT = File.expand_path('..', __dir__)

  def self.build(destination)
    release = JSON.parse(File.read(File.join(__dir__, 'release.json')))
    FileUtils.mkdir_p(destination)
    FileUtils.cp_r(File.join(__dir__, 'branding', '.'), destination)
    FileUtils.cp(File.join(__dir__, 'candidate_test.rb'), File.join(destination, 'candidate_test.rb'))
    Dir.mktmpdir('sign-source') do |tmp|
      archive = File.join(tmp, 'upstream.tar.gz')
      source = File.join(tmp, 'source')
      upstream = File.join(source, 'docuseal')
      deployment = File.join(source, 'gxb-sign-deployment')
      FileUtils.mkdir_p([upstream, deployment])
      url = "https://api.github.com/repos/docusealco/docuseal/tarball/#{release.fetch('source_commit')}"
      raise 'Upstream source download failed' unless system('curl', '-fsSL', url, '-o', archive)
      raise 'Source extraction failed' unless system('tar', '-xzf', archive, '-C', upstream, '--strip-components=1')
      %w[deploy config/deploy.yml bin/deploy-sign AGENTS.md LICENSE LICENSE_ADDITIONAL_TERMS].each do |path|
        target = File.join(deployment, path)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(File.join(ROOT, path), target)
      end
      raise 'Source packaging failed' unless system({ 'COPYFILE_DISABLE' => '1' }, 'tar', '--no-xattrs', '-czf', File.join(destination, 'public/source.tar.gz'), '-C', tmp, 'source')
    end
    Dir.glob(File.join(destination, '**', '*')).each do |path|
      File.chmod(File.directory?(path) ? 0o755 : 0o644, path)
    end
  end
end

SignPackage.build(File.expand_path(ARGV.fetch(0))) if $PROGRAM_NAME == __FILE__
