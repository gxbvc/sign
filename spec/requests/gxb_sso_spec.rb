# frozen_string_literal: true

require 'jwt'

# GXB staff SSO (config/initializers/auth_gxb.rb). Public signing pages must never ask for a login.
describe 'GXB SSO' do
  let(:secret) { 'test-gxb-client-secret' }
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account:, email: 'admin@example.com', password: 'correct-password-1') }
  let(:template) { create(:template, account:, author: admin) }
  let(:token_url) { 'https://auth.gxb.vc/oauth/token' }
  let(:callback_url) { "#{Docuseal::DEFAULT_APP_URL}/auth/callback" }

  around do |example|
    previous = Rails.application.config.auth_gxb.client_secret
    Rails.application.config.auth_gxb.client_secret = secret
    example.run
  ensure
    Rails.application.config.auth_gxb.client_secret = previous
  end

  def expect_gxb_authorize_redirect
    expect(response).to have_http_status(:found)

    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)

    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq('https://auth.gxb.vc/oauth/authorize')
    expect(query['client_id']).to eq('sign')
    expect(query['redirect_uri']).to eq(callback_url)
    expect(query['state']).to be_present
    expect(query['state']).to eq(session[GxbSso::STATE_KEY])

    query['state']
  end

  def expect_public(path)
    get path

    expect(response.location.to_s).not_to include('auth.gxb.vc')
    expect(response.location.to_s).not_to include('/sign_in')
  end

  def expect_refused(message = nil)
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include('user[password]')
    expect(response.body).to include(message) if message
  end

  def start_gxb_sign_in(path = '/sign_in')
    get path

    Rack::Utils.parse_query(URI(response.location).query).fetch('state')
  end

  def stub_token(claims, token_secret = secret)
    defaults = { 'exp' => 5.minutes.from_now.to_i, 'iss' => 'https://auth.gxb.vc', 'aud' => 'sign' }
    token = JWT.encode(defaults.merge(claims).compact, token_secret, 'HS256')

    stub_request(:post, token_url).to_return(status: 200, body: { access_token: token }.to_json,
                                             headers: { 'Content-Type' => 'application/json' })
  end

  def staff_signed_in?
    get '/templates'

    response.status == 200
  end

  describe 'public pages with no session' do
    let(:submission) { create(:submission, :with_submitters, template:, created_by_user: admin) }
    let(:submitter) { submission.submitters.first }

    it 'opens a pending signing link' do
      expect_public("/s/#{submitter.slug}")

      expect(response).to have_http_status(:ok)
    end

    it 'opens the signer data routes used by a pending signing page' do
      expect_public("/s/#{submitter.slug}/download")
      expect(response).to have_http_status(:ok)

      expect_public("/s/#{submitter.slug}/values?field_uuid=#{template.fields.first['uuid']}")
      expect(response).to have_http_status(:ok)

      blob = submission.schema_documents.first.blob
      expect_public(ActiveStorage::Blob.proxy_path(blob, expires_at: 5.minutes.from_now.to_i))
      expect(response).to have_http_status(:ok)
    end

    it 'sends a completed signing link to its completed page' do
      submitter.update!(completed_at: Time.current)
      submission.update!(completed_at: Time.current)

      expect_public("/s/#{submitter.slug}")
      expect(response).to redirect_to("/s/#{submitter.slug}/completed")

      expect_public("/s/#{submitter.slug}/completed")
      expect(response).to have_http_status(:ok)
    end

    it 'downloads completed documents for the signer' do
      create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))
      submitter.update!(completed_at: Time.current)
      submission.update!(completed_at: Time.current)

      expect_public("/s/#{submitter.slug}/documents")
      expect(response).to have_http_status(:ok)

      expect_public("/e/#{submission.slug}")
      expect(response.status).to be_in([200, 302])
    end

    it 'opens a shared template link' do
      template.update!(shared_link: true)

      expect_public("/d/#{template.slug}")

      expect(response).to have_http_status(:ok)
    end

    it 'keeps /up public' do
      expect_public('/up')

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'staff pages' do
    it 'redirects a staff page to auth.gxb.vc and stores the return path' do
      get '/templates'

      expect_gxb_authorize_redirect
      expect(session['user_return_to']).to eq('/templates')
    end

    it 'redirects GET /sign_in to auth.gxb.vc' do
      get '/sign_in'

      expect_gxb_authorize_redirect
    end

    it 'ignores the old ?password=1 fallback' do
      get '/sign_in?password=1'

      expect_gxb_authorize_redirect
    end

    it 'never signs in with a password, even a correct one' do
      post '/sign_in', params: { user: { email: admin.email, password: 'correct-password-1' } }

      expect(response).to redirect_to('/sign_in')
      expect(staff_signed_in?).to be(false)
    end

    it 'never signs in with a password and a correct two-factor code' do
      admin.update!(otp_required_for_login: true, otp_secret: User.generate_otp_secret)

      post '/sign_in', params: { user: { email: admin.email, password: 'correct-password-1',
                                         otp_attempt: admin.current_otp } }

      expect(staff_signed_in?).to be(false)
    end

    it 'turns off Devise params (password) authentication' do
      expect(Devise.params_authenticatable).to be(false)
    end

    it 'sends every password reset page to GXB sign-in without sending mail or changing the password' do
      token = admin.send(:set_reset_password_token)
      digest = admin.reload.encrypted_password

      get '/password/new'
      expect(response).to redirect_to('/sign_in')

      expect do
        post '/password', params: { user: { email: admin.email } }
      end.not_to change(ActionMailer::Base.deliveries, :size)
      expect(response).to redirect_to('/sign_in')

      get '/password/edit', params: { reset_password_token: token }
      expect(response).to redirect_to('/sign_in')

      put '/password', params: { user: { reset_password_token: token, password: 'new-password-123',
                                         password_confirmation: 'new-password-123' } }
      expect(response).to redirect_to('/sign_in')
      expect(admin.reload.encrypted_password).to eq(digest)
      expect(staff_signed_in?).to be(false)
    end

    it 'keeps the API 401 JSON without a token' do
      get '/api/templates'

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Not authenticated')
    end

    it 'keeps a JSON 401 for non-HTML staff requests' do
      get '/templates', headers: { 'Accept' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.location).to be_nil
    end
  end

  describe 'GET /auth/callback' do
    it 'refuses a bad state without a session or a token request' do
      start_gxb_sign_in

      get '/auth/callback', params: { state: 'wrong', code: 'abc' }

      expect_refused
      expect(a_request(:post, token_url)).not_to have_been_made
      expect(staff_signed_in?).to be(false)
    end

    it 'refuses a callback that was never started' do
      get '/auth/callback', params: { state: 'anything', code: 'abc' }

      expect_refused
      expect(staff_signed_in?).to be(false)
    end

    it 'refuses when the token exchange fails' do
      state = start_gxb_sign_in
      stub_request(:post, token_url).to_return(status: 400, body: '{"error":"invalid_grant"}')

      get '/auth/callback', params: { state:, code: 'abc' }

      expect_refused
      expect(staff_signed_in?).to be(false)
    end

    it 'refuses a token signed with another secret' do
      state = start_gxb_sign_in
      stub_token({ 'sub' => 'uid-1', 'email' => admin.email }, 'another-secret')

      get '/auth/callback', params: { state:, code: 'abc' }

      expect_refused
      expect(admin.reload.auth_uid).to be_nil
      expect(staff_signed_in?).to be(false)
    end

    [
      ['without exp', { 'exp' => nil }],
      ['after exp', { 'exp' => 1.minute.ago.to_i }],
      ['from another issuer', { 'iss' => 'https://evil.example' }],
      ['for another client', { 'aud' => 'sites' }]
    ].each do |label, override|
      it "refuses a token #{label}" do
        state = start_gxb_sign_in
        stub_token({ 'sub' => 'uid-1', 'email' => admin.email }.merge(override))

        get '/auth/callback', params: { state:, code: 'abc' }

        expect_refused
        expect(admin.reload.auth_uid).to be_nil
        expect(staff_signed_in?).to be(false)
      end
    end

    it 'signs in an existing user by email, backfills auth_uid, and returns to the stored path' do
      state = start_gxb_sign_in('/templates')
      stub_token('sub' => 'uid-1', 'email' => admin.email.upcase)

      get '/auth/callback', params: { state:, code: 'abc' }

      expect(response).to redirect_to('/templates')
      expect(a_request(:post, token_url).with(body: hash_including('code' => 'abc', 'client_id' => 'sign',
                                                                   'client_secret' => secret,
                                                                   'redirect_uri' => callback_url)))
        .to have_been_made
      expect(admin.reload.auth_uid).to eq('uid-1')
      expect(staff_signed_in?).to be(true)
    end

    it 'signs in by auth_uid when the email changed' do
      admin.update!(auth_uid: 'uid-1')
      state = start_gxb_sign_in
      stub_token('sub' => 'uid-1', 'email' => 'new-address@gxb.vc')

      get '/auth/callback', params: { state:, code: 'abc' }

      expect(response).to redirect_to('/')
      expect(staff_signed_in?).to be(true)
    end

    it 'provisions an unknown @gxb.vc user' do
      state = start_gxb_sign_in
      stub_token('sub' => 'uid-ricky', 'email' => 'ricky@gxb.vc', 'name' => 'Ricky Bureau')

      expect { get '/auth/callback', params: { state:, code: 'abc' } }.to change(User, :count).by(1)

      user = User.find_by(email: 'ricky@gxb.vc')
      expect(user).to have_attributes(account:, auth_uid: 'uid-ricky', role: 'admin', first_name: 'Ricky',
                                      last_name: 'Bureau')
      expect(staff_signed_in?).to be(true)
    end

    it 'refuses an unknown non-gxb user' do
      state = start_gxb_sign_in
      stub_token('sub' => 'uid-2', 'email' => 'someone@example.org')

      expect { get '/auth/callback', params: { state:, code: 'abc' } }.not_to change(User, :count)

      expect_refused
      expect(staff_signed_in?).to be(false)
    end

    it 'refuses and does not rebind an email bound to another subject' do
      admin.update!(auth_uid: 'uid-original')
      state = start_gxb_sign_in
      stub_token('sub' => 'uid-other', 'email' => admin.email)

      get '/auth/callback', params: { state:, code: 'abc' }

      expect_refused('different GXB account')
      expect(admin.reload.auth_uid).to eq('uid-original')
      expect(staff_signed_in?).to be(false)
    end

    it 'refuses an archived user' do
      admin.update!(auth_uid: 'uid-1')
      create(:user, account:)
      admin.update!(archived_at: Time.current)
      state = start_gxb_sign_in
      stub_token('sub' => 'uid-1', 'email' => admin.email)

      get '/auth/callback', params: { state:, code: 'abc' }

      expect_refused
      expect(staff_signed_in?).to be(false)
    end

    it 'refuses gxbot' do
      state = start_gxb_sign_in
      stub_token('sub' => 'uid-bot', 'email' => 'gxbot@gxb.vc')

      expect { get '/auth/callback', params: { state:, code: 'abc' } }.not_to change(User, :count)

      expect_refused
    end
  end

  describe 'with a blank client secret' do
    let(:secret) { nil }

    it 'shows "not configured" and never a password form' do
      get '/sign_in'
      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include('GXB sign-in is not configured')
      expect(response.body).not_to include('user[password]')

      get '/templates'
      expect(response).to redirect_to('/sign_in')
    end

    it 'fails closed at /auth/callback' do
      get '/auth/callback', params: { state: 'x', code: 'abc' }

      expect_refused
      expect(a_request(:post, token_url)).not_to have_been_made
      expect(staff_signed_in?).to be(false)
    end
  end
end
