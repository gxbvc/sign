# frozen_string_literal: true

# Run only in the disposable candidate container, never against production data.
abort 'Not a disposable branding check' unless ENV['SIGN_BRANDING_CHECK'] == 'true'
abort 'Candidate database must be empty' if User.exists? || Account.exists?

account = Account.create!(name: 'GXB Sign test')
User.create!(account: account, email: 'branding@example.invalid', password: SecureRandom.hex(24))
session = ActionDispatch::Integration::Session.new(Rails.application)
session.host!('localhost')
session.get('/')
raise "Landing status #{session.response.status}" unless session.response.status == 200
html = Nokogiri::HTML(session.response.body)
raise 'Wrong page title' unless html.at_css('title').text.strip == 'GXB Sign'
raise 'Wrong heading' unless html.at_css('h1').text.strip == 'GXB Sign'
raise 'Missing attribution' unless html.css('a').any? { |a| a.text == 'DocuSeal' && a['href'].start_with?('https://www.docuseal.com') }
raise 'Missing source' unless html.at_css('a[href="/gxb-sign/source.tar.gz"]')
raise 'Wrong OG image' unless html.at_css('meta[property="og:image"]')['content'] == 'http://localhost/gxb-sign/og-image.png'
raise 'Wrong favicon' unless html.at_css('link[type="image/svg+xml"]')['href'] == '/gxb-sign/favicon.svg'
session.get('/manifest.json')
manifest = JSON.parse(session.response.body)
raise 'Wrong manifest' unless manifest['name'] == 'GXB Sign' && manifest['icons'].size == 3
session.get('/setup')
raise 'Setup still open' unless session.response.redirect?
message = Mail.new(from: 'Old name <old@example.invalid>', to: 'test@example.invalid', subject: 'Header check', body: 'Not sent')
ActionMailerConfigsInterceptor.delivering_email(message)
raise 'Wrong From address' unless message.from == ['sign@gxb.vc']
raise 'Wrong From name' unless message[:from].display_names == ['GXB Sign']
puts 'PASS: Rails landing, metadata, attribution, source, manifest, setup lock, and unsent mail headers'
