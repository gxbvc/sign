# frozen_string_literal: true

# Called only by Kamal's dotenv command substitution in .kamal/secrets. Never log the result.
#   ruby deploy/secret.rb smtp SMTP_PASSWORD
#   ruby deploy/secret.rb auth AUTH_GXB_CLIENT_SECRET
# Each source is a JSON object in a file owned by the deploying user with mode 0600.
require 'json'

SOURCES = {
  'smtp' => { env: 'SIGN_SMTP_FILE', path: '~/.config/sign/smtp.json', keys: %w[SMTP_USERNAME SMTP_PASSWORD] },
  'auth' => { env: 'SIGN_AUTH_FILE', path: '~/.config/sign/auth.json', keys: %w[AUTH_GXB_CLIENT_SECRET] }
}.freeze

begin
  source = SOURCES.fetch(ARGV.fetch(0))
  key = ARGV.fetch(1)
  raise ArgumentError unless ARGV.size == 2 && source.fetch(:keys).include?(key)

  path = ENV.fetch(source.fetch(:env), File.expand_path(source.fetch(:path)))
  stat = File.stat(path)
  raise ArgumentError unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?

  value = JSON.parse(File.read(path)).fetch(key)
  raise ArgumentError unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n\x00]/)

  # Dotenv 3.2 expands variables after commands. Preserve literal dollar signs.
  print value.gsub(/\$(?!\()/) { '\\$' }
rescue StandardError
  warn 'Secret unavailable: check the protected JSON file, permissions, and requested source and key'
  exit 1
end
