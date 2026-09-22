# GXB Sign

Free DocuSeal at https://sign.gxb.vc on DigitalOcean `gxb-nyc1` (`104.131.24.46`, NYC3).

## Deployment

This checkout contains an older upstream source tree. Production uses the **unmodified official image**, not a build of this tree. `deploy/release.json` pins its release, digest, source commit, and upstream CI runs. Do not mix the local source version with the production version.

- Deployment tooling: `BUNDLE_GEMFILE=deploy/Gemfile bundle install`.
- Checks: `ruby deploy/check.rb`, `ruby -c bin/deploy-sign`, `git diff --check`.
- The release check requires successful upstream RSpec, RuboCop, ERB lint, ESLint, Brakeman, and image build for the exact release commit. It does not claim to run the older source tree's suite locally.
- Commit deployment changes on `master`, then `bin/deploy-sign`.
- Logs: `BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app logs -n 80`.
- Production runner: `BUNDLE_GEMFILE=deploy/Gemfile kamal-cli runner FILE.rb`. The container starts in `/app`; `WORKDIR=/data/docuseal` still controls persistent data.

The public image is pulled by digest over SSH, then activated through `kamal app boot`. This avoids Kamal's registry-login requirement for `deploy -P`. The registry values in `config/deploy.yml` are deliberately unused placeholders, not credentials. Do not run a source build, push to upstream, or run a registry login with these values. The existing shared kamal-proxy must already be running. Do not restart or replace it for this app.

## Data and safety

- Persistent Docker volume: `sign_storage`, mounted at `/data/docuseal`. It holds SQLite, uploaded documents, and generated signing/encryption secrets. Never delete it or print its secrets.
- Initialize the first admin privately, before publishing the proxy route. The public setup route must no longer accept account creation.
- The free license requires original DocuSeal attribution. Do not remove it or enable paid features without approval.
- Initial deployment is review-only: outbound SMTP is deliberately disabled. No invitations have been authorized.
- Imported agreements are drafts for review. Do not alter contract terms or send signature requests without approval.
- `plans/01-*` through `03-*` are old proposals, not proof of the current configuration. This file and `deploy/README.md` describe the actual deployment.
