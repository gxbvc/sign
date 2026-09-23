# frozen_string_literal: true

# Run through kamal-cli runner. Authenticate and reset an envelope, never send mail.
require 'net/smtp'
require 'timeout'
require 'json'

begin
  settings = ActionMailer::Base.smtp_settings
  raise 'Unexpected SMTP configuration' unless settings[:address] == 'smtp.mailgun.org' && settings[:port].to_i == 587
  raise 'SMTP TLS verification disabled' unless settings[:enable_starttls] && settings[:openssl_verify_mode] == OpenSSL::SSL::VERIFY_PEER

  message = Mail.new(from: 'Example <example@example.invalid>', to: 'unused@example.invalid')
  ActionMailerConfigsInterceptor.delivering_email(message)
  raise 'Unexpected sender' unless message.from == ['sign@gxb.vc'] && message[:from].decoded.include?('GXB Sign')

  Timeout.timeout(30) do
    smtp = Net::SMTP.new(settings.fetch(:address), settings.fetch(:port).to_i)
    smtp.open_timeout = 10
    smtp.read_timeout = 10
    smtp.enable_starttls
    smtp.start(helo: settings.fetch(:domain), user: settings.fetch(:user_name), secret: settings.fetch(:password), authtype: :plain) do |session|
      raise 'Envelope sender rejected' unless session.mailfrom('sign@gxb.vc').success?

      session.rset
    end
  end
  puts JSON.generate(smtp_auth: 'passed', tls: 'verified', sender: 'GXB Sign <sign@gxb.vc>', envelope_sender: 'accepted', message_sent: false)
rescue StandardError => e
  warn "SMTP verification failed: #{e.class} (details withheld to protect credentials)"
  exit 1
end
