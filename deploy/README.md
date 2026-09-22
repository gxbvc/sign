# GXB Sign deployment

- URL: https://sign.gxb.vc
- Server: DigitalOcean `gxb-nyc1`, `104.131.24.46`, NYC3.
- Edition: free, unmodified DocuSeal 3.2.6. Required attribution retained.
- Release: `release.json` records the immutable image digest and source commit.
- Routing: the server's existing kamal-proxy provides HTTPS on ports 80/443. DocuSeal's port 3000 is only on the Docker network.
- Data: Docker volume `sign_storage` at `/data/docuseal`, including SQLite, attachments and generated keys. Container replacements retain this volume.
- Email: disabled until a separate sending request and SMTP setup. This deployment is for document review.

## Commands

From `~/projects/sign`:

```sh
BUNDLE_GEMFILE=deploy/Gemfile bundle install
ruby deploy/check.rb
ruby -c bin/deploy-sign
git diff --check
# Commit approved changes on master before deployment.
bin/deploy-sign
BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app version
BUNDLE_GEMFILE=deploy/Gemfile bundle exec kamal app logs -n 80
curl -I https://sign.gxb.vc/up
```

The check script validates the deployment configuration and checks the exact release commit's successful upstream RSpec, Ruby/ERB/JavaScript lint, security scan, and Docker build. Local infrastructure checks run here. No local application code is included in the deployed image, and the older source tree's tests are not represented as local release tests.

Kamal's normal `deploy -P` performs a registry login, even for public images. `bin/deploy-sign` instead verifies the shared proxy is running, pulls the pinned digest anonymously, tags that artifact with its release version, and uses `kamal app boot`. It does not change or restart the shared proxy. Do not use the unused registry placeholders to attempt a login.

## First initialization

Before the public proxy route was enabled, the candidate was started as `sign-bootstrap` with port 3000 bound only to server loopback at port 3306. An SSH tunnel exposed it locally at port 13306 for first-admin setup. The bootstrap process must be stopped before the production process uses the same volume. Close the SSH tunnel after setup. Never expose an unclaimed setup form publicly.

## Upgrade and recovery

1. Select an upstream release with all required CI checks passing.
2. Record its source commit and Docker digest in `release.json`.
3. Back up the full data volume and test recovery before any upgrade that changes the database.
4. Run the checks, commit, and deploy.

Do not roll back an application image across an incompatible database migration. Never run `kamal app remove` or remove `sign_storage` as a routine redeploy.

Persistent storage is configured. Automated off-server backups and SMTP are not part of this initial review deployment; configure them before using the app for executed agreements.
