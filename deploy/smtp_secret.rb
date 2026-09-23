# frozen_string_literal: true

# Called only by Kamal's dotenv command substitution. Never log the result.
require 'json'

begin
  key = ARGV.fetch(0)
  raise ArgumentError unless %w[SMTP_USERNAME SMTP_PASSWORD].include?(key)

  path = ENV.fetch('SIGN_SMTP_FILE', File.expand_path('~/.config/sign/smtp.json'))
  stat = File.stat(path)
  raise ArgumentError unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?

  value = JSON.parse(File.read(path)).fetch(key)
  raise ArgumentError unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n\x00]/)

  # Dotenv 3.2 expands variables after commands. Preserve literal dollar signs.
  print value.gsub(/\$(?!\()/) { '\\$' }
rescue StandardError
  warn 'SMTP secret unavailable: check the protected JSON file, permissions, and requested key'
  exit 1
end
