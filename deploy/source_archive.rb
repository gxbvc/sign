# frozen_string_literal: true

require 'fileutils'
require 'open3'

# Write the AGPL source archive that the Dockerfile copies to /gxb-sign/source.tar.gz.
# It holds exactly the tracked files of one commit (git archive): no credentials, user data, or ignored files.
# OPERATOR_ONLY is left out: operator notes and deploy tooling with client names, host names and the server
# address, not program source. The public mirror (publish_source.rb) leaves out the same paths, in all history.
module SignSourceArchive
  ROOT = File.expand_path('..', __dir__)
  PATH = File.join(__dir__, 'build', 'source.tar.gz')
  # Public repo cleanup (Security's scan of the public gxbvc repos, Nov 20): plans/ (since Oct), plus the operator
  # notes and the deploy checks that name a client, the host or its IP. deploy/branding and deploy/release.json stay
  # public (the image and the attribution use them).
  OPERATOR_ONLY = %w[
    plans
    AGENTS.md
    config/deploy.yml
    deploy/README.md
    deploy/candidate.rb
    deploy/candidate_test.rb
    deploy/candidate_data_test.rb
    deploy/check.rb
    deploy/test_public_source.rb
  ].freeze

  def self.write(commit, path = PATH)
    raise 'Invalid commit' unless commit.match?(/\A[a-f0-9]{40}\z/)

    FileUtils.mkdir_p(File.dirname(path))
    ok = system('git', '-C', ROOT, 'archive', '--format=tar.gz', '--prefix=gxb-sign/', '-o', path, commit,
                '--', '.', *OPERATOR_ONLY.map { |p| ":(exclude)#{p}" })
    raise 'git archive failed' unless ok

    verify(commit, path)
    path
  end

  # git archive stores the commit id in the tar header; git get-tar-commit-id reads it back.
  def self.verify(commit, path = PATH)
    tar, status = Open3.capture2('gzip', '-dc', path, binmode: true)
    raise 'Source archive unreadable' unless status.success?

    id, status = Open3.capture2('git', '-C', ROOT, 'get-tar-commit-id', stdin_data: tar, binmode: true)
    raise "Source archive is for #{id.strip.inspect}, not #{commit}" unless status.success? && id.strip == commit

    true
  end

  # True when an archive entry (prefixed gxb-sign/) is an operator-only path or under one.
  def self.operator_only_entry?(entry)
    rel = entry.delete_prefix('gxb-sign/')
    OPERATOR_ONLY.any? { |p| rel == p || rel.start_with?("#{p}/") }
  end
end

if $PROGRAM_NAME == __FILE__
  commit = ARGV.fetch(0) { `git -C #{SignSourceArchive::ROOT} rev-parse HEAD`.strip }
  puts SignSourceArchive.write(commit)
end
