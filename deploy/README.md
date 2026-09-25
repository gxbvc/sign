# GXB Sign deployment

- URL: https://sign.gxb.vc
- Server: DigitalOcean `gxb-nyc1`, `104.131.24.46`, NYC3.
- Upstream: free DocuSeal 3.2.6 source (commit in `release.json`). This checkout is that source plus the GXB overlay, built as `ghcr.io/gxbvc/sign:<commit>` on the host's remote BuildKit.
- Branding: `branding/` is baked into the image by the GXB block in `Dockerfile` (same paths the old read-only mounts used). Required DocuSeal attribution remains. No paid features are enabled.
- Version: the deployment Git commit is the image tag and the container name. The app reports 3.2.6 from `ARG DOCUSEAL_VERSION`.
- Routing: the existing shared kamal-proxy provides HTTPS. The app's port 3000 stays on the Docker network.
- Data: `sign_storage:/data/docuseal` holds SQLite, attachments, and generated keys. Never remove it.

## Checks and deployment

```sh
BUNDLE_GEMFILE=deploy/Gemfile bundle install
ruby deploy/check.rb
ruby -c bin/deploy-sign
git diff --check
# Commit changes on master. Take a volume backup to /opt/sign/backups/ first when data or migrations change.
bin/deploy-sign 20260925-163905-sign_storage.tar.gz
BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app version
BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app logs -n 80
ruby deploy/verify.rb
```

`check.rb` verifies successful upstream RSpec, Ruby/ERB/JavaScript lint, security scan, and Docker build for the exact release commit. It runs Ruby lint for the deployment layer and local tests for metadata, document title suffixes, private previews, attribution, the manifest, and icon dimensions. The older checkout's Rails suite is not the deployed suite.

`check.rb` also proves that the tree outside the GXB overlay equals the upstream commit, except the files listed in `release.json` `gxb_changed_upstream_files`.

`prepare.rb COMMIT BACKUP` pulls our image on the host and runs two disposable candidates. Neither has a public port, the production volume, or SMTP credentials, and each uses its own `--internal` network and temp volume that are removed after the checks, including on failure. Candidate A uses an empty volume: landing page, metadata, attribution, source link, manifest, setup lock after a throwaway account, unsent email headers, editor branding, and every public asset. Candidate B restores the named backup without `dump.rdb` (so no queued jobs run) and proves the schema is unchanged by boot, no migrations are pending, Bailey v6 is completed, and `/setup` redirects.

`bin/deploy-sign BACKUP` requires a clean tree. It runs the checks and the shared-proxy precheck, writes the source archive, logs in to GHCR with `gh auth token`, builds and pushes, runs both candidates, then `kamal redeploy --skip-push`. That pulls and boots the app. It does not boot or change the shared proxy and never runs `app remove`.

Release directories are not overwritten. If activation fails after preparation, inspect the failure and existing release before retrying. Keep directories referenced by running or rollback containers. Remove only unused candidate directories after inspection.

## Branding and source

The initializer prepends the custom view directory to Rails controllers, including the standalone PWA controller. It does not change `Docuseal.product_name`, license checks, email attribution, or signing logic. The Vue document editor has a separate inline logo. `builder-branding-v1.css` displays the signature icon in that home link while keeping Vue's DOM and its 40px size intact. The selector is limited to the editor header; other SVGs and attribution are unchanged. The candidate also checks the authenticated editor layout. Use a new stylesheet filename when changing it because public assets are cached. Metadata keeps upstream private-preview suppression and per-document titles.

The Lucide Signature SVG is white on a black circle. Its license is in `branding/LUCIDE-LICENSE`. PNG and ICO versions are committed. To regenerate icons, use ImageMagick with a transparent background and the required dimensions. Public files are normalized to readable permissions during packaging.

`branding/public/og-image.html` is the editable 1200×630 share image. Render with:

```sh
html-to-image deploy/branding/public/og-image.html --scale 1
```

Every deployment publishes `/gxb-sign/source.tar.gz`, linked from the retained DocuSeal footer. It is `git archive` of the deployed commit (`deploy/source_archive.rb`), without `plans/`: the full DocuSeal source, the GXB changes, and these build instructions. No credentials, user data, or documents are included. `docker build .` after writing the archive reproduces the image.

## Data, mail, and recovery

The first admin was initialized privately before the route was published. Verify `/setup` redirects rather than accepting public account creation.

Outgoing mail uses Mailgun at `smtp.mailgun.org:587`, with required STARTTLS and certificate verification. The visible sender is `GXB Sign <sign@gxb.vc>`. Authentication uses the existing `auth@gxb.vc` Mailgun domain credential; the SMTP login does not determine the visible sender. The domain is verified, and authentication plus the `sign@gxb.vc` envelope sender have been accepted without sending a test message.

Credentials are stored outside Git in `~/.config/sign/smtp.json`, owned by the deploying user with mode 0600. It is a JSON object with `SMTP_USERNAME` and `SMTP_PASSWORD`. `.kamal/secrets` uses `deploy/smtp_secret.rb` to load these values into Kamal's secret environment file. Do not run the loader directly or print `kamal config`. `SIGN_SMTP_FILE` can select a different protected file. The source archive contains only the loader and template, never credential values. Tests use fake credentials and check permissions and literal special characters.

To verify authentication from the deployed container without sending mail:

```sh
BUNDLE_GEMFILE=deploy/Gemfile kamal-cli runner deploy/verify_smtp.rb
```

Christian approved the existing queued invitation to `ricky@gxb.vc` on 2026-09-22. Its existing queued job was retried immediately at his request and completed on 2026-09-22. No extra test message or signature request is authorized. Before changing providers or enabling mail again, inspect pending jobs so old messages do not send unexpectedly.

Imported agreements remain drafts. Do not send signature requests or change contract terms without approval. Automated off-server backups must be configured before using the app for executed agreements.

Before upgrading upstream, back up the full volume and test recovery. Select a release whose required upstream CI passes, update `release.json`, and repeat candidate checks. Do not roll back across incompatible database migrations. Containers from before 2026-09-25 used the official image with `/opt/sign/branding/<commit>` host mounts; keep those directories until a rollback to them is no longer needed. Never run `kamal app remove` or remove the persistent volume during redeployment.
