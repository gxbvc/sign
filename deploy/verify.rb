# frozen_string_literal: true

require 'net/http'
require 'json'
require 'digest'
require 'zlib'
require 'stringio'
require 'rubygems/package'

origin = 'https://sign.gxb.vc'
fetch = lambda do |path|
  response = Net::HTTP.get_response(URI("#{origin}#{path}"))
  abort "FAIL: #{path} returned #{response.code}" unless response.code == '200'
  response.body
end

fetch.call('/up')
html = fetch.call('/')
abort 'FAIL: title' unless html.match?(%r{<title>\s*GXB Sign\s*</title>})
abort 'FAIL: OG title' unless html.include?('property="og:title" content="GXB Sign"')
abort 'FAIL: OG image' unless html.include?("#{origin}/gxb-sign/og-image.png")
abort 'FAIL: favicon' unless html.include?('href="/gxb-sign/favicon.svg"')
abort 'FAIL: builder branding stylesheet' unless html.include?('href="/gxb-sign/builder-branding-v1.css"')
abort 'FAIL: DocuSeal credit' unless html.include?('Based on <a href="https://github.com/docusealco/docuseal"')
abort 'FAIL: powered-by footer' if html.match?(/powered by/i)
abort 'FAIL: source link' unless html.include?('href="https://github.com/gxbvc/sign"')
manifest = JSON.parse(fetch.call('/manifest.json'))
abort 'FAIL: manifest name' unless manifest['name'] == 'GXB Sign'
Dir[File.join(__dir__, 'branding/public/*')].each do |path|
  next unless File.file?(path)

  actual = fetch.call("/gxb-sign/#{File.basename(path)}")
  abort "FAIL: asset differs: #{path}" unless Digest::SHA256.hexdigest(actual) == Digest::SHA256.file(path).hexdigest
end
%w[favicon.svg favicon.ico].each do |name|
  abort "FAIL: root #{name}" unless fetch.call("/#{name}") == File.binread(File.join(__dir__, 'branding/public', name))
end
source = Zlib::GzipReader.new(StringIO.new(fetch.call('/gxb-sign/source.tar.gz'))).read
entries = Gem::Package::TarReader.new(StringIO.new(source)).map(&:full_name)
%w[gxb-sign/LICENSE gxb-sign/LICENSE_ADDITIONAL_TERMS gxb-sign/Dockerfile gxb-sign/deploy/release.json gxb-sign/deploy/branding/initializer.rb].each do |path|
  abort "FAIL: source archive missing #{path}" unless entries.include?(path)
end
abort "FAIL: source archive has ignored or secret files" if entries.any? { |path| path.match?(%r{\Agxb-sign/(deploy/build/|config/master\.key|\.env|plans/)}) }
setup = Net::HTTP.get_response(URI("#{origin}/setup"))
abort 'FAIL: public setup is not locked' unless %w[301 302 303].include?(setup.code)
puts 'PASS: live health, metadata, manifest, exact public assets, source archive, attribution, and setup lock'
