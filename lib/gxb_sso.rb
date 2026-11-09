# frozen_string_literal: true

require 'jwt'

# auth.gxb.vc OAuth helpers shared by the Devise failure app, /sign_in, and AuthCallbacksController.
# Settings come from config/initializers/auth_gxb.rb.
module GxbSso
  STATE_KEY = 'gxb_oauth_state'
  # auth.gxb.vc signs every access token with this issuer, even when AUTH_GXB_URL points elsewhere.
  ISSUER = 'https://auth.gxb.vc'
  CALLBACK_PATH = '/auth/callback'
  STAFF_CHECK_TIMEOUT = 5

  # A good code exchange: the verified claims and the access token they came from. The token stays in memory
  # only, for the live staff check (staff?). It is never logged or stored, and inspect does not show it.
  class Identity
    attr_reader :claims, :access_token

    def initialize(claims, access_token)
      @claims = claims
      @access_token = access_token
    end

    def inspect
      '#<GxbSso::Identity>'
    end
    alias to_s inspect
  end

  module_function

  def config
    Rails.application.config.auth_gxb
  end

  def enabled?
    config.client_secret.present?
  end

  # Built from APP_URL (https://sign.gxb.vc in production), never from request.host.
  def callback_url
    URI.join(Docuseal::DEFAULT_APP_URL, CALLBACK_PATH).to_s
  end

  def authorize_url(session, email: nil)
    session[STATE_KEY] = SecureRandom.hex(32)

    query = {
      client_id: config.client_id,
      redirect_uri: callback_url,
      state: session[STATE_KEY],
      # A prefill hint for the auth.gxb.vc form only. It never selects an account.
      email: login_hint(email)
    }.compact.to_query

    "#{config.base_url}/oauth/authorize?#{query}"
  end

  def login_hint(email)
    email = email.to_s.strip.downcase

    email if email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
  end

  def valid_state?(expected, returned)
    expected.present? && returned.present? && ActiveSupport::SecurityUtils.secure_compare(expected, returned)
  end

  # Exchanges the authorization code and returns an Identity (verified JWT claims plus the access token), or nil.
  def identity_for_code(code)
    return unless enabled?

    response = exchange_code(code)

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("GXB SSO token exchange failed: HTTP #{response.code}")

      return
    end

    token = JSON.parse(response.body)['access_token'].to_s

    claims = JWT.decode(token, config.client_secret, true,
                        algorithm: 'HS256', required_claims: %w[exp sub],
                        iss: ISSUER, verify_iss: true, aud: config.client_id, verify_aud: true).first

    Identity.new(claims, token)
  rescue JWT::DecodeError, JSON::ParserError, SocketError, SystemCallError, Timeout::Error,
         OpenSSL::SSL::SSLError, Net::HTTPBadResponse => e
    Rails.logger.warn("GXB SSO callback failed: #{e.class}")

    nil
  end

  def exchange_code(code)
    uri = URI("#{config.base_url}/oauth/token")

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 10) do |http|
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(code:, client_id: config.client_id, client_secret: config.client_secret,
                            redirect_uri: callback_url)

      http.request(request)
    end
  end

  # Asks auth.gxb.vc live whether this person is GXB staff now. Auth's /oauth/userinfo reads `staff` from the
  # user record, never from the token, so a person Auth marks as not staff (a contractor with a gxb.vc address)
  # is false even with a valid token. True only for HTTP 200 whose `sub` equals the JWT sub and whose `staff` is
  # the JSON value true. Every other answer or error is false (fail closed). The log line has a reason word
  # only, never the token, the email or other claims.
  def staff?(access_token, sub)
    return staff_refused('no_token') if access_token.blank? || sub.blank?

    response = fetch_userinfo(access_token)
    return staff_refused('http_status') unless response.is_a?(Net::HTTPOK)

    body = JSON.parse(response.body.to_s)
    return staff_refused('bad_json') unless body.is_a?(Hash)
    return staff_refused('sub_mismatch') unless body['sub'].is_a?(String) && body['sub'] == sub.to_s
    return staff_refused('staff_missing') unless body.key?('staff')
    return staff_refused('not_staff') unless body['staff'] == true

    true
  rescue JSON::ParserError
    staff_refused('bad_json')
  rescue Timeout::Error
    staff_refused('timeout')
  rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    staff_refused('network')
  end

  def fetch_userinfo(access_token)
    uri = URI("#{config.base_url}/oauth/userinfo")

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: STAFF_CHECK_TIMEOUT,
                                        read_timeout: STAFF_CHECK_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{access_token}"
      request['Accept'] = 'application/json'

      http.request(request)
    end
  end

  def staff_refused(reason)
    Rails.logger.warn("GXB SSO staff check refused a new user: #{reason}")

    false
  end
end
