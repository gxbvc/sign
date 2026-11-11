# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'lock_compare'

class LockCompareTest < Minitest::Test
  UPSTREAM = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        nokogiri (1.19.4)
        nokogiri (1.19.4-x86_64-linux-gnu)
        rack (3.2.6)
        rubyzip (3.2.2)

    PLATFORMS
      ruby
      x86_64-linux

    DEPENDENCIES
      nokogiri
      rack
      rubyzip

    RUBY VERSION
       ruby 4.0.5

    BUNDLED WITH
       4.0.3
  LOCK

  def problems(current)
    LockCompare.problems(UPSTREAM, current)
  end

  def test_identical_lock_passes
    assert_empty problems(UPSTREAM)
  end

  def test_version_only_change_passes
    current = UPSTREAM.gsub('nokogiri (1.19.4', 'nokogiri (1.19.7').sub('rack (3.2.6)', 'rack (3.2.8)').sub('rubyzip (3.2.2)', 'rubyzip (3.7.0)')
    refute_equal UPSTREAM, current
    assert_empty problems(current)
  end

  def test_new_gem_fails_with_its_name
    current = UPSTREAM.sub("    rubyzip (3.2.2)\n", "    rubyzip (3.2.2)\n    evilgem (0.1.0)\n")
    assert_equal ['new gem: evilgem'], problems(current)
  end

  def test_removed_gem_fails_with_its_name
    current = UPSTREAM.sub("    rubyzip (3.2.2)\n", '')
    assert_equal ['removed gem: rubyzip'], problems(current)
  end

  def test_git_source_fails
    current = UPSTREAM.sub("GEM\n", "GIT\n  remote: https://github.com/example/rack.git\n  revision: abc123\n  specs:\n    rack (3.2.6)\n\nGEM\n")
                      .sub("    rack (3.2.6)\n\nPLATFORMS", "\nPLATFORMS")
    found = problems(current)
    assert(found.any? { |line| line.start_with?('source is not rubygems.org only: git source https://github.com/example/rack.git') }, found.inspect)
  end

  def test_path_source_fails
    current = UPSTREAM.sub("GEM\n", "PATH\n  remote: vendor/rack\n  specs:\n    rack (3.2.6)\n\nGEM\n")
    found = problems(current)
    assert(found.any? { |line| line.include?('path source') }, found.inspect)
  end

  def test_new_rubygems_remote_fails
    current = UPSTREAM.sub('remote: https://rubygems.org/', "remote: https://rubygems.org/\n  remote: https://gems.example.com/")
    found = problems(current)
    assert_includes found, 'new source: https://gems.example.com'
  end

  def test_new_platform_fails_with_its_name
    current = UPSTREAM.sub("  x86_64-linux\n", "  x86_64-linux\n  arm64-darwin\n")
    assert_equal ['new platform: arm64-darwin'], problems(current)
  end

  def test_removed_platform_fails
    current = UPSTREAM.sub("  x86_64-linux\n", '')
    assert_includes problems(current), 'removed platform: x86_64-linux'
  end

  def test_new_platform_variant_of_a_gem_fails_with_its_name
    current = UPSTREAM.sub("    nokogiri (1.19.4-x86_64-linux-gnu)\n", "    nokogiri (1.19.4-x86_64-linux-gnu)\n    nokogiri (1.19.4-arm64-darwin)\n")
    assert_equal ['nokogiri: new platform variant arm64-darwin'], problems(current)
  end

  def test_source_only_accepts_plain_rubygems
    assert_empty LockCompare.source_only_problems(UPSTREAM)
  end

  def test_source_only_rejects_git
    text = "GIT\n  remote: https://github.com/example/x.git\n  revision: abc\n  specs:\n    x (1.0)\n\n#{UPSTREAM}"
    refute_empty LockCompare.source_only_problems(text)
  end
end
