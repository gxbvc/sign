# frozen_string_literal: true

require 'tmpdir'

# Mirror this repo to the public source repo (AGPL section 13), without plans/ (operator notes with client names).
# History is rewritten in a throwaway clone, so public commit ids differ from local ones. The local repo is untouched.
# Needs git-filter-repo and a GitHub login that can push to gxbvc/sign.
module SignPublishSource
  ROOT = File.expand_path('..', __dir__)
  REMOTE = 'https://github.com/gxbvc/sign.git'
  BRANCH = 'master'

  def self.run(commit)
    raise 'Invalid commit' unless commit.match?(/\A[a-f0-9]{40}\z/)

    ENV['PATH'] = [File.join(Dir.home, 'Library/Python/3.9/bin'), ENV.fetch('PATH')].join(':')
    Dir.mktmpdir('sign-public') do |tmp|
      clone = File.join(tmp, 'sign')
      git(tmp, 'clone', '--quiet', '--no-local', '--no-tags', ROOT, clone)
      git(clone, 'checkout', '--quiet', '-B', BRANCH, commit)
      git(clone, 'filter-repo', '--quiet', '--force', '--invert-paths', '--path', 'plans')
      git(clone, 'push', '--force', REMOTE, "#{BRANCH}:#{BRANCH}")
    end
    true
  end

  def self.git(dir, *args)
    raise "git #{args.first} failed" unless system('git', '-C', dir, *args)
  end
end

SignPublishSource.run(ARGV.fetch(0) { `git -C #{SignPublishSource::ROOT} rev-parse HEAD`.strip }) if $PROGRAM_NAME == __FILE__
