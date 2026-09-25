# frozen_string_literal: true

require 'fileutils'
require 'open3'

# Write the AGPL source archive that the Dockerfile copies to /gxb-sign/source.tar.gz.
# It holds exactly the tracked files of one commit (git archive): no credentials, user data, or ignored files.
# plans/ is excluded: it is operator notes with client names, not program source.
module SignSourceArchive
  ROOT = File.expand_path('..', __dir__)
  PATH = File.join(__dir__, 'build', 'source.tar.gz')

  def self.write(commit)
    raise 'Invalid commit' unless commit.match?(/\A[a-f0-9]{40}\z/)

    FileUtils.mkdir_p(File.dirname(PATH))
    ok = system('git', '-C', ROOT, 'archive', '--format=tar.gz', '--prefix=gxb-sign/', '-o', PATH, commit,
                '--', '.', ':(exclude)plans')
    raise 'git archive failed' unless ok

    verify(commit)
    PATH
  end

  # git archive stores the commit id in the tar header; git get-tar-commit-id reads it back.
  def self.verify(commit, path = PATH)
    tar, status = Open3.capture2('gzip', '-dc', path, binmode: true)
    raise 'Source archive unreadable' unless status.success?

    id, status = Open3.capture2('git', '-C', ROOT, 'get-tar-commit-id', stdin_data: tar, binmode: true)
    raise "Source archive is for #{id.strip.inspect}, not #{commit}" unless status.success? && id.strip == commit

    true
  end
end

if $PROGRAM_NAME == __FILE__
  commit = ARGV.fetch(0) { `git -C #{SignSourceArchive::ROOT} rev-parse HEAD`.strip }
  puts SignSourceArchive.write(commit)
end
