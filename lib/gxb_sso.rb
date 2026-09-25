# frozen_string_literal: true

require 'jwt'

# auth.gxb.vc OAuth helpers shared by the Devise failure app, /sign_in, and AuthCallbacksController.
# Settings come from config/initializers/auth_gxb.rb.
module GxbSso
  STATE_KEY = 'gxb_oauth_state'
  # auth.gxb.vc signs every access token with this issuer, even when AUTH_GXB_URL points elsewhere.
  ISSUER = 'https://auth.gxb.vc'
  CALLBACK_PATH = '/auth/callback'

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

  # Exchanges the authorization code and returns the verified JWT claims, or nil.
  def claims_for_code(code)
    return unless enabled?

    response = exchange_code(code)

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("GXB SSO token exchange failed: HTTP #{response.code}")

      return
    end

    token = JSON.parse(response.body)['access_token'].to_s

    JWT.decode(token, config.client_secret, true,
               algorithm: 'HS256', required_claims: %w[exp sub],
               iss: ISSUER, verify_iss: true, aud: config.client_id, verify_aud: true).first
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
end
