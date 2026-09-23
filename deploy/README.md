# GXB Sign deployment

- URL: https://sign.gxb.vc
- Server: DigitalOcean `gxb-nyc1`, `104.131.24.46`, NYC3.
- Upstream: free DocuSeal 3.2.6, pulled by the digest in `release.json`. No source build.
- Branding: `branding/` is a read-only presentation layer over the official image. Required DocuSeal attribution remains. No paid features are enabled.
- Version: the deployment Git commit identifies the container and `/opt/sign/branding/COMMIT` directory.
- Routing: the existing shared kamal-proxy provides HTTPS. The app's port 3000 stays on the Docker network.
- Data: `sign_storage:/data/docuseal` holds SQLite, attachments, and generated keys. Never remove it.

## Checks and deployment

```sh
BUNDLE_GEMFILE=deploy/Gemfile bundle install
ruby deploy/check.rb
ruby -c bin/deploy-sign
git diff --check
# Use a unique candidate ID. This never mounts production storage.
ruby deploy/prepare.rb check-YYYYMMDD-HHMMSS
# Commit changes on master, then:
bin/deploy-sign
BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app version
BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app logs -n 80
ruby deploy/verify.rb
```

`check.rb` verifies successful upstream RSpec, Ruby/ERB/JavaScript lint, security scan, and Docker build for the exact release commit. It runs Ruby lint for the deployment layer and local tests for metadata, document title suffixes, private previews, attribution, the manifest, and icon dimensions. The older checkout's Rails suite is not the deployed suite.

`prepare.rb` downloads corresponding upstream source, packages the branding layer, uploads it to a new immutable directory, and starts a disposable container. The candidate has no public port, production volume, or SMTP credentials. Real Rails checks cover the landing page, metadata, attribution, source link, manifest, setup lock, and unsent email headers. HTTP checks confirm every public asset. The candidate is stopped after the checks, including on failure. Failed candidate directories are retained for inspection.

`bin/deploy-sign` requires committed deployment files. It repeats checks and candidate tests, tags the same official image with the deployment commit, and uses `kamal app boot`. It does not run a registry login or change the shared proxy. Registry fields in `config/deploy.yml` are unused placeholders.

Release directories are not overwritten. If activation fails after preparation, inspect the failure and existing release before retrying. Keep directories referenced by running or rollback containers. Remove only unused candidate directories after inspection.

## Branding and source

The initializer prepends the custom view directory to Rails controllers, including the standalone PWA controller. It does not change `Docuseal.product_name`, license checks, email attribution, or signing logic. Metadata keeps upstream private-preview suppression and per-document titles.

The Lucide Signature SVG is white on a black circle. Its license is in `branding/LUCIDE-LICENSE`. PNG and ICO versions are committed. To regenerate icons, use ImageMagick with a transparent background and the required dimensions. Public files are normalized to readable permissions during packaging.

`branding/public/og-image.html` is the editable 1200×630 share image. Render with:

```sh
html-to-image deploy/branding/public/og-image.html --scale 1
```

Every deployment publishes `/gxb-sign/source.tar.gz`, linked from the retained DocuSeal footer. It contains the pinned upstream source and this deployment layer, including build/deployment instructions. No credentials, user data, or documents are included. To reproduce the presentation layer, use the pinned upstream image with the mounts in `config/deploy.yml`; the image itself is unchanged.

## Data, mail, and recovery

The first admin was initialized privately before the route was published. Verify `/setup` redirects rather than accepting public account creation.

Outgoing mail uses Mailgun at `smtp.mailgun.org:587`, with required STARTTLS and certificate verification. The visible sender is `GXB Sign <sign@gxb.vc>`. Authentication uses the existing `auth@gxb.vc` Mailgun domain credential; the SMTP login does not determine the visible sender. The domain is verified, and authentication plus the `sign@gxb.vc` envelope sender have been accepted without sending a test message.

Credentials are stored outside Git in `~/.config/sign/smtp.json`, owned by the deploying user with mode 0600. It is a JSON object with `SMTP_USERNAME` and `SMTP_PASSWORD`. `.kamal/secrets` uses `deploy/smtp_secret.rb` to load these values into Kamal's secret environment file. Do not run the loader directly or print `kamal config`. `SIGN_SMTP_FILE` can select a different protected file. The source archive contains only the loader and template, never credential values. Tests use fake credentials and check permissions and literal special characters.

To verify authentication from the deployed container without sending mail:

```sh
BUNDLE_GEMFILE=deploy/Gemfile kamal-cli runner deploy/verify_smtp.rb
```

Christian approved the existing queued invitation to `ricky@gxb.vc` on 2026-09-22. It remains queued for its normal retry. No extra test message or signature request is authorized. Before changing providers or enabling mail again, inspect pending jobs so old messages do not send unexpectedly.

Imported agreements remain drafts. Do not send signature requests or change contract terms without approval. Automated off-server backups must be configured before using the app for executed agreements.

Before upgrading upstream, back up the full volume and test recovery. Select a release whose required upstream CI passes, update `release.json`, and repeat candidate checks. Do not roll back across incompatible database migrations. A branding-only rollback to an earlier branded commit needs its original image tag and `SIGN_DEPLOY_VERSION` mount directory. Never run `kamal app remove` or remove the persistent volume during redeployment.
