# GXB Sign

Free DocuSeal at https://sign.gxb.vc on DigitalOcean `gxb-nyc1` (`104.131.24.46`, NYC3).

## Deployment

This checkout contains an older upstream source tree. Production pulls the **official image by digest**, not a build of this tree, and mounts the presentation files in `deploy/branding` read-only. `deploy/release.json` pins the upstream release, digest, source commit, and CI runs. The container version and branding directory use the deployment Git commit. Do not mix the local source version with the production version.

- Deployment tooling: `BUNDLE_GEMFILE=deploy/Gemfile bundle install`.
- Checks: `ruby deploy/check.rb`, `ruby -c bin/deploy-sign`, `git diff --check`. Run `ruby deploy/prepare.rb check-UNIQUE-ID` before committing to test the candidate against the actual image.
- The release check requires successful upstream RSpec, RuboCop, ERB lint, ESLint, Brakeman, and image build for the exact release commit. It also tests the branding templates and image dimensions. The disposable candidate tests real Rails rendering and static assets without the production volume. The older source tree's suite is not the deployed suite.
- Commit deployment changes on `master`, then `bin/deploy-sign`.
- Logs: `BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app logs -n 80`.
- Production runner: `BUNDLE_GEMFILE=deploy/Gemfile kamal-cli runner FILE.rb`. The container starts in `/app`; `WORKDIR=/data/docuseal` still controls persistent data.

The public image is pulled by digest over SSH, then activated through `kamal app boot`. This avoids Kamal's registry-login requirement for `deploy -P`. The registry values in `config/deploy.yml` are deliberately unused placeholders, not credentials. Do not run a source build, push to upstream, or run a registry login with these values. The existing shared kamal-proxy must already be running. Do not restart or replace it for this app.

## Data and safety

- Persistent Docker volume: `sign_storage`, mounted at `/data/docuseal`. It holds SQLite, uploaded documents, and generated signing/encryption secrets. Never delete it or print its secrets.
- Initialize the first admin privately, before publishing the proxy route. The public setup route must no longer accept account creation.
- The free license requires original DocuSeal attribution. Do not remove it or enable paid features without approval.
- Outbound mail uses Mailgun (`smtp.mailgun.org:587`, required STARTTLS and certificate verification). The sender is `GXB Sign <sign@gxb.vc>`. `.kamal/secrets` loads credentials from protected `~/.config/sign/smtp.json`; never print or commit its values.
- Christian authorized the existing queued invitation to `ricky@gxb.vc` on 2026-09-22. Do not send other invitations without approval.
- Imported agreements are drafts for review. Do not alter contract terms or send signature requests without approval.
- `plans/01-*` through `03-*` are old proposals, not proof of the current configuration. This file and `deploy/README.md` describe the actual deployment.
