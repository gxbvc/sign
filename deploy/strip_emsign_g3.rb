# Remove only the compromised emSign ECC Root CA - G3 from Alpine's final CA bundle.
# Fingerprint is SHA-256 of the DER certificate, not a name or a different G3 root.
require "openssl"

path = ARGV.fetch(0)
bundle = File.binread(path)
pem_pattern = /-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\r?\n?/m
certificates = bundle.scan(pem_pattern)
abort "Unexpected CA bundle size" if certificates.length < 100

target = "86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b"
removed = 0
filtered = bundle.gsub(pem_pattern) do |pem|
  certificate = OpenSSL::X509::Certificate.new(pem)
  if OpenSSL::Digest.hexdigest("SHA256", certificate.to_der) == target
    removed += 1
    ""
  else
    pem
  end
end
abort "Expected exactly one emSign ECC G3 root, found #{removed}" unless removed == 1
abort "Unexpected CA bundle change" unless filtered.scan(pem_pattern).length == certificates.length - 1

# No later build step must regenerate the bundle from the old APK.
temporary = "#{path}.filtered-#{Process.pid}"
begin
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(filtered) }
  File.rename(temporary, path)
ensure
  File.delete(temporary) if File.exist?(temporary)
end
puts "Removed exact emSign ECC Root CA - G3; retained #{certificates.length - 1} roots"
