# frozen_string_literal: true

# Run only in the disposable candidate container, never against production data.
abort 'Not a disposable branding check' unless ENV['SIGN_BRANDING_CHECK'] == 'true'
abort 'Candidate database must be empty' if User.exists? || Account.exists?

account = Account.create!(name: 'GXB Sign test')
password = SecureRandom.hex(24)
user = User.create!(account: account, email: 'branding@example.invalid', password:)
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
raise 'Missing Vue builder branding' unless html.at_css('link[rel="stylesheet"][href="/gxb-sign/builder-branding-v1.css"]')
session.get('/manifest.json')
manifest = JSON.parse(session.response.body)
raise 'Wrong manifest' unless manifest['name'] == 'GXB Sign' && manifest['icons'].size == 3
session.get('/setup')
raise 'Setup still open' unless session.response.redirect?
# GXB SSO with the fake candidate secret. The redirect is never followed (no egress).
staff = ActionDispatch::Integration::Session.new(Rails.application)
staff.host!('localhost')
staff.get('/templates')
authorize = URI(staff.response.location.to_s)
query = Rack::Utils.parse_query(authorize.query)
raise "Staff page status #{staff.response.status}" unless staff.response.status == 302
raise 'Staff page not sent to GXB' unless "#{authorize.host}#{authorize.path}" == 'auth.gxb.vc/oauth/authorize'
raise 'Wrong GXB client or callback' unless query['client_id'] == 'sign' && query['redirect_uri'] == 'http://localhost/auth/callback'
staff.get('/sign_in')
raise 'Sign-in not sent to GXB' unless staff.response.location.to_s.start_with?('https://auth.gxb.vc/oauth/authorize?')
staff.get('/sign_in?password=1')
raise 'Old password fallback not sent to GXB' unless staff.response.location.to_s.start_with?('https://auth.gxb.vc/')
# Password sign-in is off: a correct password must not sign in, and reset links go to GXB sign-in.
raise 'Devise params authentication is on' unless Devise.params_authenticatable == false
staff.post('/sign_in', params: { user: { email: user.email, password: } })
raise "Password POST status #{staff.response.status}" unless staff.response.location.to_s.end_with?('/sign_in')
staff.get('/templates')
raise 'Correct password signed in' unless staff.response.location.to_s.start_with?('https://auth.gxb.vc/')
staff.get('/password/edit?reset_password_token=wrong')
raise 'Password reset page not sent to sign-in' unless staff.response.location.to_s.end_with?('/sign_in')
staff.get('/auth/callback?state=wrong&code=wrong')
raise "Bad callback not refused: #{staff.response.status}" unless staff.response.status == 403
# Chat host API with the fake candidate key. Lists tools only; never calls a tool.
chat_key = ENV.fetch('CHAT_API_KEY')
chat = ActionDispatch::Integration::Session.new(Rails.application)
chat.host!('localhost')
chat.get('/chat_api/tools', headers: { 'X-Auth-Email' => user.email })
raise "Chat API without a key: #{chat.response.status}" unless chat.response.status == 401
chat.get('/chat_api/tools', headers: { 'Authorization' => "Bearer #{chat_key}" })
raise "Chat API without an identity: #{chat.response.status}" unless chat.response.status == 403
chat.get('/chat_api/tools', headers: { 'Authorization' => "Bearer #{chat_key}", 'X-Auth-Email' => user.email })
raise "Chat API tools status #{chat.response.status}" unless chat.response.status == 200
raise 'Chat API set a cookie' if chat.response.headers['Set-Cookie'].present?
chat_tools = JSON.parse(chat.response.body).fetch('tools').index_by { |tool| tool.fetch('name') }
raise "Chat API tools #{chat_tools.keys.sort}" unless chat_tools.keys.sort ==
                                                      %w[create_template load_template search_documents
                                                         search_templates send_documents]
raise 'send_documents does not require confirmation' unless chat_tools['send_documents']['requires_confirmation'] == true
raise 'send_documents approval is not bound' unless chat_tools['send_documents']['confirmation_binding'] == 'template_id'
raise 'send_documents not destructive' unless chat_tools['send_documents'].dig('annotations', 'destructiveHint') == true
message = Mail.new(from: 'Old name <old@example.invalid>', to: 'test@example.invalid', subject: 'Header check', body: 'Not sent')
ActionMailerConfigsInterceptor.delivering_email(message)
raise 'Wrong From address' unless message.from == ['sign@gxb.vc']
raise 'Wrong From name' unless message[:from].display_names == ['GXB Sign']
require 'warden/test/helpers'
Warden.test_mode!
Warden.on_next_request { |proxy| proxy.set_user(user, scope: :user) }
template = Template.create!(account: account, author: user, name: 'Disposable editor check')
session.get("/templates/#{template.id}/edit")
raise "Editor status #{session.response.status}" unless session.response.status == 200
editor = Nokogiri::HTML(session.response.body)
raise 'Missing editor' unless editor.at_css('template-builder')
raise 'Missing editor branding stylesheet' unless editor.at_css('link[href="/gxb-sign/builder-branding-v1.css"]')
Warden.test_reset!
puts 'PASS: Rails landing, metadata, attribution, source, manifest, setup lock, GXB SSO redirect, password sign-in off, ' \
     'Chat API tools (401, 403, five tools, send_documents needs confirmation), unsent mail headers, ' \
     'and authenticated editor branding'
