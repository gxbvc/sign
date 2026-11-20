# frozen_string_literal: true

require 'tmpdir'
require_relative 'source_archive'

# Mirror this repo to the public source repo (AGPL section 13), without the operator-only paths
# (SignSourceArchive::OPERATOR_ONLY: plans/, operator notes and deploy checks with client names, host and IP).
# History is rewritten in a throwaway clone, so public commit ids differ from local ones, and those paths are gone
# from every public commit. The local repo is untouched.
# Needs git-filter-repo and a GitHub login that can push to gxbvc/sign.
module SignPublishSource
  ROOT = File.expand_path('..', __dir__)
  REMOTE = 'https://github.com/gxbvc/sign.git'
  BRANCH = 'master'

  def self.filter_args
    ['filter-repo', '--quiet', '--force', '--invert-paths',
     *SignSourceArchive::OPERATOR_ONLY.flat_map { |p| ['--path', p] }]
  end

  def self.run(commit)
    raise 'Invalid commit' unless commit.match?(/\A[a-f0-9]{40}\z/)

    ENV['PATH'] = [File.join(Dir.home, 'Library/Python/3.9/bin'), ENV.fetch('PATH')].join(':')
    Dir.mktmpdir('sign-public') do |tmp|
      clone = File.join(tmp, 'sign')
      git(tmp, 'clone', '--quiet', '--no-local', '--no-tags', ROOT, clone)
      git(clone, 'checkout', '--quiet', '-B', BRANCH, commit)
      git(clone, *filter_args)
      git(clone, 'push', '--force', REMOTE, "#{BRANCH}:#{BRANCH}")
    end
    true
  end

  def self.git(dir, *args)
    raise "git #{args.first} failed" unless system('git', '-C', dir, *args)
  end
end

SignPublishSource.run(ARGV.fetch(0) { `git -C #{SignPublishSource::ROOT} rev-parse HEAD`.strip }) if $PROGRAM_NAME == __FILE__
