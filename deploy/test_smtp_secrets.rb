# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'dotenv'

class SmtpSecretsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('sign-smtp-test')
    @path = File.join(@directory, 'smtp.json')
    @values = { 'SMTP_USERNAME' => 'test@example.invalid', 'SMTP_PASSWORD' => %q(test-$HOME-${PASSWORD}-\$HOME-$(id)-'"special) }
    File.write(@path, JSON.generate(@values), perm: 0o600)
    @previous = ENV['SIGN_SMTP_FILE']
    ENV['SIGN_SMTP_FILE'] = @path
  end

  def teardown
    ENV['SIGN_SMTP_FILE'] = @previous
    File.unlink(@path)
    Dir.rmdir(@directory)
  end

  # Parse only the SMTP lines. Other lines (for example the registry token) run real commands,
  # and a failure diff must never print their values.
  def test_kamal_dotenv_round_trip
    root = File.expand_path('..', __dir__)
    lines = File.readlines(File.join(root, '.kamal/secrets')).grep(/\ASMTP_/)
    assert_equal(%w[SMTP_USERNAME SMTP_PASSWORD], lines.map { |line| line.split('=', 2).first })
    subset = File.join(@directory, 'secrets')
    File.write(subset, lines.join, perm: 0o600)
    Dir.chdir(root) do
      assert_equal @values, Dotenv.parse(subset, overwrite: true)
    end
  ensure
    File.unlink(subset) if subset && File.exist?(subset)
  end

  def test_rejects_readable_secret_file_without_leaking
    File.chmod(0o644, @path)
    stdout, stderr, status = Open3.capture3('ruby', File.join(__dir__, 'smtp_secret.rb'), 'SMTP_PASSWORD')
    refute status.success?
    assert_empty stdout
    refute_includes stderr, @values.fetch('SMTP_PASSWORD')
  end

  def test_rejects_unknown_key
    stdout, _, status = Open3.capture3('ruby', File.join(__dir__, 'smtp_secret.rb'), 'OTHER')
    refute status.success?
    assert_empty stdout
  end
end
