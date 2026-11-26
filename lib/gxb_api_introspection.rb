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
  CONNECTION_KEY = :gxb_api_auth_connection
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

  # One kept-alive connection to Auth per Puma thread, so a cache miss costs one request, not a new TCP and TLS
  # handshake (measured Nov 26: 40 to 130 ms per new connection on the busy host, Auth itself 6 to 11 ms).
  # A kept connection that Auth closed meanwhile is opened again once; a second failure is Unavailable.
  def post(token)
    request = Net::HTTP::Post.new(url)
    request['Authorization'] = "Bearer #{secret}"
    request['Accept'] = 'application/json'
    request.set_form_data(token:)

    attempts = 0
    begin
      attempts += 1
      connection.request(request)
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError # IOError includes EOFError
      reset_connection!
      retry if attempts < 2
      raise
    rescue StandardError
      reset_connection!
      raise
    end
  end

  def connection
    uri = url
    http = Thread.current[CONNECTION_KEY]
    return http if http&.started? && http.address == uri.host && http.port == uri.port

    reset_connection!
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 2
    http.read_timeout = 3
    http.write_timeout = 3
    http.keep_alive_timeout = 30
    http.start
    Thread.current[CONNECTION_KEY] = http
  end

  def reset_connection!
    http = Thread.current[CONNECTION_KEY]
    Thread.current[CONNECTION_KEY] = nil
    http.finish if http&.started?
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  end

  def clear_cache!
    CACHE.clear
  end
end
