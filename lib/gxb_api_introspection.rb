# frozen_string_literal: true

require 'net/http'

# Checks a GXB API (api.gxb.vc) exchanged token by introspection at auth.gxb.vc (service contract, section 2.1).
# The token is never decoded here, never logged and never stored: the cache key is a SHA-256 of it.
# AUTH_INTROSPECTION_SECRET is Sign's own introspection caller secret at Auth (from ~/.config/sign/auth.json at
# deploy). With no secret, every check is Unavailable (503), never a pass.
module GxbApiIntrospection
  Unavailable = Class.new(StandardError)

  CACHE_SECONDS = 60
  INACTIVE = { 'active' => false }.freeze
  CACHE = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

  module_function

  def secret
    ENV.fetch('AUTH_INTROSPECTION_SECRET', '').presence
  end

  def url
    URI("#{Rails.application.config.auth_gxb.base_url}/oauth/introspect")
  end

  # The introspection answer (a Hash; {"active" => false} for a refused token). Raises Unavailable when Auth
  # cannot answer (no secret, network error, timeout, 408, 429, 5xx, or a body that is not a JSON object).
  def call(token)
    key = Digest::SHA256.hexdigest(token.to_s)
    cached = CACHE.read(key)
    return cached if cached

    claims = fetch(token)
    remember(key, claims)

    claims
  end

  def fetch(token)
    raise Unavailable, 'no introspection secret' if secret.nil?

    response = post(token)
    code = response.code.to_i
    raise Unavailable, "HTTP #{code}" if code >= 500 || [408, 429].include?(code)
    return INACTIVE unless response.is_a?(Net::HTTPOK)

    body = JSON.parse(response.body.to_s)
    raise Unavailable, 'not a JSON object' unless body.is_a?(Hash)

    body
  rescue JSON::ParserError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
         Net::HTTPBadResponse => e
    raise Unavailable, e.class.name
  end

  # Only an active answer is kept: at most 60 s and never past exp.
  def remember(key, claims)
    return unless claims['active'] == true

    seconds = [CACHE_SECONDS, claims['exp'].to_i - Time.now.to_i].min
    CACHE.write(key, claims, expires_in: seconds) if seconds.positive?
  end

  def post(token)
    uri = url

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 2, read_timeout: 3) do |http|
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{secret}"
      request['Accept'] = 'application/json'
      request.set_form_data(token:)

      http.request(request)
    end
  end

  def clear_cache!
    CACHE.clear
  end
end
