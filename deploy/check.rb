# Deployment checks for the unmodified upstream image, not the stale source tree.
require "json"
require "yaml"
require "net/http"
require "open3"

ROOT = File.expand_path("..", __dir__)
config = YAML.safe_load_file(File.join(ROOT, "config/deploy.yml"))
release = JSON.parse(File.read(File.join(__dir__, "release.json")))

def check(name, condition)
  abort "FAIL: #{name}" unless condition
  puts "PASS: #{name}"
end

check("internal-services host", config.dig("servers", "web", "hosts") == ["104.131.24.46"])
check("HTTPS domain", config.dig("proxy", "host") == "sign.gxb.vc" && config.dig("proxy", "ssl") == true)
check("health endpoint", config.dig("proxy", "healthcheck", "path") == "/up")
check("persistent storage", config.fetch("volumes") == ["sign_storage:/data/docuseal"])
check("no public app port", !config.dig("servers", "web", "options").key?("publish"))
check("mail disabled", config.dig("env", "clear", "SMTP_ADDRESS") == "127.0.0.1" && config.dig("env", "clear", "SMTP_PORT") == "1")
check("upstream image", release.fetch("image") == "docuseal/docuseal" && config.fetch("image") == release.fetch("image"))
check("pinned digest", release.fetch("digest").match?(/\Asha256:[a-f0-9]{64}\z/))
check("numeric release", release.fetch("version").match?(/\A\d+\.\d+\.\d+\z/))
check("copyright retained", File.read(File.join(ROOT, "LICENSE_ADDITIONAL_TERMS")).include?("retain the original DocuSeal attribution"))

stdout, status = Open3.capture2("gh", "api", "repos/docusealco/docuseal/commits/#{release.fetch('source_commit')}/check-runs")
check("release CI evidence fetched", status.success?)
checks = JSON.parse(stdout).fetch("check_runs")
%w[RSpec Rubocop Erblint ESLint Brakeman build].each do |name|
  latest = checks.select { |run| run.fetch("name") == name }.max_by { |run| run.fetch("id") }
  check("release #{name}", latest && latest.fetch("conclusion") == "success")
end

if ARGV.include?("--bootstrap")
  response = Net::HTTP.get_response(URI("http://127.0.0.1:13306/up"))
  check("candidate health", response.code == "200")
end
