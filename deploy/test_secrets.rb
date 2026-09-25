# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'dotenv'

# Fake credentials in a temp directory only. HOME also points there, so a missed override can never
# reach ~/.config/sign. The real .kamal/secrets file is compared as text and never evaluated.
class SecretsTest < Minitest::Test
  LOADER_LINES = [
    "SMTP_USERNAME=$(ruby deploy/secret.rb smtp SMTP_USERNAME)\n",
    "SMTP_PASSWORD=$(ruby deploy/secret.rb smtp SMTP_PASSWORD)\n",
    "AUTH_GXB_CLIENT_SECRET=$(ruby deploy/secret.rb auth AUTH_GXB_CLIENT_SECRET)\n",
    "CHAT_API_KEY=$(ruby deploy/secret.rb chat CHAT_API_KEY)\n"
  ].freeze

  def setup
    @directory = Dir.mktmpdir('sign-secret-test')
    @smtp_path = File.join(@directory, 'smtp.json')
    @auth_path = File.join(@directory, 'auth.json')
    @smtp = { 'SMTP_USERNAME' => 'test@example.invalid',
              'SMTP_PASSWORD' => %q(test-$HOME-${PASSWORD}-\$HOME-$(id)-'"special) }
    @auth = { 'AUTH_GXB_CLIENT_SECRET' => %q(fake-auth-$HOME-${X}-$(id)-'"secret) }
    @chat_path = File.join(@directory, 'chat.json')
    @chat = { 'CHAT_API_KEY' => %q(fake-chat-$HOME-${KEY}-$(id)-'"key) }
    File.write(@smtp_path, JSON.generate(@smtp), perm: 0o600)
    File.write(@auth_path, JSON.generate(@auth), perm: 0o600)
    File.write(@chat_path, JSON.generate(@chat), perm: 0o600)
    @previous = ENV.to_h.slice('SIGN_SMTP_FILE', 'SIGN_AUTH_FILE', 'SIGN_CHAT_FILE', 'HOME')
    ENV['SIGN_SMTP_FILE'] = @smtp_path
    ENV['SIGN_AUTH_FILE'] = @auth_path
    ENV['SIGN_CHAT_FILE'] = @chat_path
    ENV['HOME'] = @directory
  end

  def teardown
    %w[SIGN_SMTP_FILE SIGN_AUTH_FILE SIGN_CHAT_FILE HOME].each { |key| ENV[key] = @previous[key] }
    FileUtils.remove_entry(@directory)
  end

  def root
    File.expand_path('..', __dir__)
  end

  def loader(*args)
    Open3.capture3('ruby', File.join(__dir__, 'secret.rb'), *args)
  end

  def test_kamal_secrets_use_the_loader
    lines = File.readlines(File.join(root, '.kamal/secrets')).grep(/\A(SMTP_|AUTH_GXB_|CHAT_API_)/)
    assert_equal LOADER_LINES, lines
  end

  # Same lines, parsed by Kamal's dotenv from a temp copy, against the fake files.
  def test_kamal_dotenv_round_trip
    subset = File.join(@directory, 'secrets')
    File.write(subset, LOADER_LINES.join, perm: 0o600)
    Dir.chdir(root) do
      assert_equal @smtp.merge(@auth, @chat), Dotenv.parse(subset, overwrite: true)
    end
  end

  def test_rejects_readable_secret_files_without_leaking
    [[@smtp_path, %w[smtp SMTP_PASSWORD], @smtp['SMTP_PASSWORD']],
     [@auth_path, %w[auth AUTH_GXB_CLIENT_SECRET], @auth['AUTH_GXB_CLIENT_SECRET']],
     [@chat_path, %w[chat CHAT_API_KEY], @chat['CHAT_API_KEY']]].each do |path, args, value|
      File.chmod(0o644, path)
      stdout, stderr, status = loader(*args)
      refute status.success?
      assert_empty stdout
      refute_includes stderr, value
    end
  end

  def test_rejects_unknown_source_or_key
    [%w[smtp OTHER], %w[auth SMTP_PASSWORD], %w[smtp AUTH_GXB_CLIENT_SECRET], %w[other SMTP_PASSWORD],
     %w[chat AUTH_GXB_CLIENT_SECRET], %w[auth CHAT_API_KEY], %w[smtp CHAT_API_KEY],
     %w[SMTP_PASSWORD], %w[smtp SMTP_PASSWORD extra]].each do |args|
      stdout, _, status = loader(*args)
      refute status.success?, args.join(' ')
      assert_empty stdout
    end
  end

  def test_rejects_missing_file
    File.unlink(@auth_path)
    stdout, _, status = loader('auth', 'AUTH_GXB_CLIENT_SECRET')
    refute status.success?
    assert_empty stdout

    File.unlink(@chat_path)
    stdout, _, status = loader('chat', 'CHAT_API_KEY')
    refute status.success?
    assert_empty stdout
  end
end
