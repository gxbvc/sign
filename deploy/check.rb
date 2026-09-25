# Check the Kamal config, the GXB overlay, and that the rest of this tree is the pinned upstream commit.
require "json"
require "yaml"
require "open3"
require "erb"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
config = YAML.safe_load(ERB.new(File.read(File.join(ROOT, "config/deploy.yml"))).result)
release = JSON.parse(File.read(File.join(__dir__, "release.json")))
# Paths that exist only in the GXB overlay. Everything else must match upstream, except the allowlist in release.json.
OVERLAY = %w[plans deploy AGENTS.md config/deploy.yml .kamal bin/deploy-sign].freeze

def check(name, condition)
  abort "FAIL: #{name}" unless condition
  puts "PASS: #{name}"
end

check("internal-services host", config.dig("servers", "web", "hosts") == ["104.131.24.46"])
check("HTTPS domain", config.dig("proxy", "host") == "sign.gxb.vc" && config.dig("proxy", "ssl") == true)
check("app port and health endpoint", config.dig("proxy", "app_port") == 3000 && config.dig("proxy", "healthcheck", "path") == "/up")
check("only the persistent volume", config.fetch("volumes") == ["sign_storage:/data/docuseal"])
check("no public app port", !config.dig("servers", "web", "options").key?("publish"))
check("rollback containers kept", config.fetch("retain_containers").to_i >= 1)
check("GHCR image", "#{config.dig('registry', 'server')}/#{config.fetch('image')}" == release.fetch("image") && release.fetch("image") == "ghcr.io/gxbvc/sign")
check("registry password from secrets", config.dig("registry", "password") == ["KAMAL_REGISTRY_PASSWORD"])
check("registry secret source", File.read(File.join(ROOT, ".kamal/secrets")).include?("KAMAL_REGISTRY_PASSWORD=$(gh auth token)"))
check("remote amd64 builder from this tree", config.dig("builder", "arch") == "amd64" && config.dig("builder", "context") == "." && config.dig("builder", "remote") == "ssh://root@104.131.24.46")
check("mail sender", config.dig("env", "clear", "SMTP_FROM") == "GXB Sign <sign@gxb.vc>")
check("Mailgun SMTP", config.dig("env", "clear", "SMTP_ADDRESS") == "smtp.mailgun.org" && config.dig("env", "clear", "SMTP_PORT") == "587")
check("verified SMTP TLS", config.dig("env", "clear", "SMTP_ENABLE_STARTTLS") == "true" && config.dig("env", "clear", "SMTP_SSL_VERIFY") == "true")
check("protected SMTP credentials", config.dig("env", "secret") == %w[SMTP_USERNAME SMTP_PASSWORD] && (config.dig("env", "clear").keys & %w[SMTP_USERNAME SMTP_PASSWORD]).empty?)
check("branding tests", system(RbConfig.ruby, File.join(__dir__, "test_branding.rb")))
ruby_files = Dir[File.join(__dir__, "*.rb")] + [File.join(__dir__, "branding/initializer.rb"), File.join(ROOT, "bin/deploy-sign")]
check("deployment Ruby lint", system({ "BUNDLE_GEMFILE" => File.join(__dir__, "Gemfile") }, "bundle", "exec", "rubocop", "--config", File.join(__dir__, "rubocop.yml"), *ruby_files))
check("SMTP secret loader tests", system({ "BUNDLE_GEMFILE" => File.join(__dir__, "Gemfile") }, "bundle", "exec", "ruby", File.join(__dir__, "test_smtp_secrets.rb")))
check("numeric release", release.fetch("version").match?(/\A\d+\.\d+\.\d+\z/))
check("copyright retained", File.read(File.join(ROOT, "LICENSE_ADDITIONAL_TERMS")).include?("retain the original DocuSeal attribution"))

dockerfile = File.read(File.join(ROOT, "Dockerfile"))
check("branding baked into image", [
  "COPY deploy/branding /opt/gxb-sign",
  "COPY deploy/branding/public /app/public/gxb-sign",
  "COPY deploy/branding/initializer.rb /app/config/initializers/gxb_sign.rb",
  "COPY deploy/branding/public/favicon.ico deploy/branding/public/favicon.svg /app/public/",
  "COPY deploy/build/source.tar.gz /app/public/gxb-sign/source.tar.gz"
].all? { |line| dockerfile.include?(line) })
check("image version matches release", File.read(File.join(ROOT, "Dockerfile")).include?("ARG DOCUSEAL_VERSION=#{release.fetch('version')}\n"))
check("upstream image layout", dockerfile.include?("WORKDIR /data/docuseal") && dockerfile.include?('CMD ["/app/bin/bundle", "exec", "puma", "-C", "/app/config/puma.rb", "--dir", "/app"]'))
dockerignore = File.read(File.join(ROOT, ".dockerignore")).lines.map(&:strip)
check("build context excludes secrets", (%w[/.git /.kamal /plans .env* /config/master.key /deploy/*] - dockerignore).empty?)
check("source archive is git-ignored", system("git", "-C", ROOT, "check-ignore", "-q", "deploy/build/source.tar.gz"))

# Tree proof: stage the working tree into a throwaway index and diff it against the upstream commit.
commit = release.fetch("source_commit")
unless system("git", "-C", ROOT, "cat-file", "-e", "#{commit}^{commit}", err: File::NULL)
  system("git", "-C", ROOT, "fetch", "--quiet", "origin", commit)
end
check("upstream commit available", system("git", "-C", ROOT, "cat-file", "-e", "#{commit}^{commit}"))
changed = Dir.mktmpdir("sign-tree-proof") do |tmp|
  index = File.join(tmp, "index")
  FileUtils.cp(File.join(ROOT, ".git/index"), index)
  env = { "GIT_INDEX_FILE" => index }
  abort "FAIL: tree proof staging" unless system(env, "git", "-C", ROOT, "add", "-A", ".")
  out, status = Open3.capture2(env, "git", "-C", ROOT, "diff", "--cached", "--name-only", commit, "--", ".", *OVERLAY.map { |path| ":!#{path}" })
  abort "FAIL: tree proof diff" unless status.success?
  out.lines.map(&:strip).sort
end
allowed = release.fetch("gxb_changed_upstream_files").sort
check("tree matches upstream #{commit[0, 12]} outside the overlay (changed: #{changed.join(', ')})", changed == allowed)

stdout, status = Open3.capture2("gh", "api", "repos/docusealco/docuseal/commits/#{commit}/check-runs")
check("release CI evidence fetched", status.success?)
checks = JSON.parse(stdout).fetch("check_runs")
%w[RSpec Rubocop Erblint ESLint Brakeman build].each do |name|
  latest = checks.select { |run| run.fetch("name") == name }.max_by { |run| run.fetch("id") }
  check("release #{name}", latest && latest.fetch("conclusion") == "success")
end
