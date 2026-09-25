# frozen_string_literal: true

require 'ipaddr'
require 'net/http'
require 'resolv'

# Fetches a public HTTPS file for the Chat create_template tool (GxbChatTools).
# Upstream DownloadUtils only refuses literal localhost names. This also refuses any host that resolves to a
# private, loopback, link-local, or reserved address, pins the connection to the checked address (no DNS
# rebinding), skips proxies, re-checks every redirect, and limits the size and the total time.
module GxbSafeDownload
  Refused = Class.new(StandardError)

  MAX_BYTES = 20.megabytes
  MAX_REDIRECTS = 3
  # Chat gives up after 30 s. Staying well under it keeps a retry from making a duplicate template.
  OPEN_TIMEOUT = 4
  READ_TIMEOUT = 5
  TOTAL_TIMEOUT = 12

  BLOCKED_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
    192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
    ::/128 ::1/128 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/23 2001:db8::/32 2002::/16 fc00::/7 fe80::/10
    fec0::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  module_function

  # Returns [body, filename].
  def fetch(url)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TOTAL_TIMEOUT
    uri = validate_url!(url)

    (MAX_REDIRECTS + 1).times do
      body, location = get(uri, deadline)
      return [body, filename(uri)] if body

      uri = validate_url!(URI.join(uri, location).to_s)
    end

    raise Refused, 'Too many redirects'
  end

  def validate_url!(url)
    uri = URI.parse(url.to_s.strip)

    raise Refused, 'Only https URLs are allowed' unless uri.is_a?(URI::HTTPS)
    raise Refused, 'Only port 443 is allowed' unless uri.port == 443
    raise Refused, 'URL must not contain a user name or password' if uri.userinfo
    raise Refused, 'URL has no host' if uri.hostname.blank?

    uri
  rescue URI::Error
    raise Refused, 'Invalid URL'
  end

  def public_address?(address)
    ip = IPAddr.new(address.to_s).native

    BLOCKED_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
  rescue IPAddr::Error
    false
  end

  # Every address must be public, so a host with one private record is refused.
  def resolve(host)
    Resolv.getaddresses(host)
  end

  def get(uri, deadline)
    raise Refused, 'Download timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    addresses = resolve(uri.hostname)
    raise Refused, 'Host does not resolve' if addresses.empty?
    raise Refused, 'Private or local addresses are not allowed' unless addresses.all? { |a| public_address?(a) }

    http = Net::HTTP.new(uri.hostname, 443, nil)
    http.ipaddr = addresses.first
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.5].max
    http.open_timeout = [OPEN_TIMEOUT, remaining].min
    http.read_timeout = [READ_TIMEOUT, remaining].min
    http.write_timeout = [READ_TIMEOUT, remaining].min
    http.max_retries = 0

    http.start do
      http.request_get(uri.request_uri) do |response|
        return [nil, response['location']] if response.is_a?(Net::HTTPRedirection) && response['location'].present?
        raise Refused, "Download failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPOK)

        return [read_limited(response, deadline), nil]
      end
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
    raise Refused, 'Download timed out'
  rescue OpenSSL::SSL::SSLError, SystemCallError, IOError, SocketError, Resolv::ResolvError
    raise Refused, 'Download failed'
  end

  def read_limited(response, deadline)
    raise Refused, 'File is too large' if response.content_length.to_i > MAX_BYTES

    body = +''
    body.force_encoding(Encoding::BINARY)

    response.read_body do |chunk|
      body << chunk
      raise Refused, 'File is too large' if body.bytesize > MAX_BYTES
      raise Refused, 'Download timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    body
  end

  def filename(uri)
    name = File.basename(URI.decode_www_form_component(uri.path.to_s))

    name.presence && name != '/' ? name : 'document.pdf'
  rescue ArgumentError
    'document.pdf'
  end
end
