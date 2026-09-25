# GXB Sign

Free DocuSeal at https://sign.gxb.vc on DigitalOcean `gxb-nyc1` (`104.131.24.46`, NYC3).

## Deployment

This checkout is DocuSeal 3.2.6 source (upstream commit `47c090e1f1548be0d8ab58347c83363539e8b5b6`) plus the GXB overlay. Production runs a **build of this tree**: `ghcr.io/gxbvc/sign:<git sha>`. Branding (`deploy/branding`) and the public source archive are baked into the image by the GXB block in `Dockerfile`. `deploy/release.json` pins the upstream version, commit, CI runs, and the list of upstream files GXB changed on purpose.

- Deployment tooling: `BUNDLE_GEMFILE=deploy/Gemfile bundle install`.
- Checks: `ruby deploy/check.rb`, `ruby -c bin/deploy-sign`, `git diff --check`. `check.rb` also proves the tree outside the overlay equals the upstream commit, except the allowlisted files.
- Deploy: commit on `master`, then `bin/deploy-sign BACKUP.tar.gz` (a tarball in `/opt/sign/backups/` on the host). It builds on the host's remote BuildKit, pushes to GHCR, runs candidate A (empty volume) and candidate B (copy of the backup on an internal network, no `dump.rdb`, no SMTP), then `kamal redeploy --skip-push`. Take a fresh backup first when the change touches data or migrations.
- Logs: `BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app logs -n 80`.
- Production runner: `BUNDLE_GEMFILE=deploy/Gemfile kamal-cli runner FILE.rb`. The container starts in `/app`; `WORKDIR=/data/docuseal` still controls persistent data. Every Rails boot, including a runner, runs `config/initializers/migrate.rb` (pending migrations) unless `RUN_MIGRATIONS=false`.

Registry login uses `gh auth token` (`KAMAL_REGISTRY_PASSWORD` in `.kamal/secrets`). Never print it. Do not push to `origin` (`docusealco/docuseal`, upstream). The existing shared kamal-proxy must already be running. Do not restart or replace it. Never run `kamal app remove`.

## Data and safety

- Persistent Docker volume: `sign_storage`, mounted at `/data/docuseal`. It holds SQLite, uploaded documents, and generated signing/encryption secrets. Never delete it or print its secrets.
- Backups: dated volume tarballs in `/opt/sign/backups/` on the host and `~/backups/sign/` on the laptop. Plan 05 has the record. Litestream (plan 03) is not live.
- `/setup` must stay locked. Public signing links (`/s`, `/d`, `/e`) must open with no login.
- The free license requires original DocuSeal attribution. Do not remove it or enable paid features without approval. `/gxb-sign/source.tar.gz` is the `git archive` of the deployed commit (without `plans/`) and must stay public.
- Outbound mail uses Mailgun (`smtp.mailgun.org:587`, required STARTTLS and certificate verification). The sender is `GXB Sign <sign@gxb.vc>`. `.kamal/secrets` loads credentials from protected `~/.config/sign/smtp.json`; never print or commit its values.
- Staff sign in with GXB (auth.gxb.vc, client `sign`). The client secret loads from protected `~/.config/sign/auth.json`; never print or commit it. `/sign_in?password=1` is the password fallback. See `deploy/README.md`.
- Christian authorized the existing queued invitation to `ricky@gxb.vc` on 2026-09-22. Do not send other invitations without approval.
- Imported agreements are drafts for review. Do not alter contract terms or send signature requests without approval.
- `plans/01-*` through `03-*` are old proposals, not proof of the current configuration. This file and `deploy/README.md` describe the actual deployment.
