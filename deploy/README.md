# GXB Sign deployment

- URL: https://sign.gxb.vc
- Server: DigitalOcean `gxb-nyc1`, `104.131.24.46`, NYC3.
- Upstream: free DocuSeal 3.2.6 source (commit in `release.json`). This checkout is that source plus the GXB overlay, built as `ghcr.io/gxbvc/sign:<commit>` on the host's remote BuildKit.
- Branding: `branding/` is baked into the image by the GXB block in `Dockerfile` (same paths the old read-only mounts used). The product name is "GXB Sign" everywhere users see it (`PRODUCT_NAME` in `lib/docuseal.rb`, locale strings, emails, PDFs). Christian approved removing the "Powered by DocuSeal" footers and email attribution on 2026-10-01; only a "Source code" link remains. No paid features are enabled.
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

`check.rb` also proves that the tree outside the GXB overlay equals the upstream commit, except the upstream files listed in `release.json` `gxb_changed_upstream_files` and the new files in `gxb_added_files`. Each GXB migration must be in `gxb_migrations`, and `db/schema.rb` must be at the newest one.

`prepare.rb COMMIT BACKUP` pulls our image on the host and runs two disposable candidates. Neither has a public port, the production volume, SMTP credentials, or the real GXB auth secret (a fake one turns on the SSO redirect, which is never followed), and each uses its own `--internal` network and temp volume that are removed after the checks, including on failure. Candidate A uses an empty volume: landing page, metadata, attribution, source link, manifest, setup lock after a throwaway account, staff page redirect to auth.gxb.vc, password sign-in and reset refused, unsent email headers, editor branding, and every public asset. Candidate B restores the named backup without `dump.rdb` (so no queued jobs run) and proves boot applied only the `gxb_migrations` (upstream schema still `production_schema_version`), no migrations are pending, Bailey v6 is completed, both Bailey signing links open their completed pages with no login, staff pages redirect to auth.gxb.vc, and `/setup` redirects.

`bin/deploy-sign BACKUP` requires a clean tree. It runs the checks and the shared-proxy precheck, writes the source archive, logs in to GHCR with `gh auth token`, builds and pushes, runs both candidates, then `kamal redeploy --skip-push`. That pulls and boots the app. It does not boot or change the shared proxy and never runs `app remove`.

Release directories are not overwritten. If activation fails after preparation, inspect the failure and existing release before retrying. Keep directories referenced by running or rollback containers. Remove only unused candidate directories after inspection.

## Branding and source

The initializer prepends the custom view directory to Rails controllers, including the standalone PWA controller. It does not change license checks or signing logic. The Vue document editor has a separate inline logo. `builder-branding-v1.css` displays the signature icon in that home link while keeping Vue's DOM and its 40px size intact. The selector is limited to the editor header; other SVGs and attribution are unchanged. The candidate also checks the authenticated editor layout. Use a new stylesheet filename when changing it because public assets are cached. Metadata keeps upstream private-preview suppression and per-document titles.

The Lucide Signature SVG is white on a black circle. Its license is in `branding/LUCIDE-LICENSE`. PNG and ICO versions are committed. To regenerate icons, use ImageMagick with a transparent background and the required dimensions. Public files are normalized to readable permissions during packaging.

`branding/public/og-image.html` is the editable 1200×630 share image. Render with:

```sh
html-to-image deploy/branding/public/og-image.html --scale 1
```

Every deployment publishes `/gxb-sign/source.tar.gz`, linked from the footer ("Source code"). It is `git archive` of the deployed commit (`deploy/source_archive.rb`), without `plans/`: the full DocuSeal source, the GXB changes, and these build instructions. No credentials, user data, or documents are included. `docker build .` after writing the archive reproduces the image.

## Data, mail, and recovery

The first admin was initialized privately before the route was published. Verify `/setup` redirects rather than accepting public account creation.

Outgoing mail uses Mailgun at `smtp.mailgun.org:587`, with required STARTTLS and certificate verification. The visible sender is `GXB Sign <sign@gxb.vc>`. Authentication uses the existing `auth@gxb.vc` Mailgun domain credential; the SMTP login does not determine the visible sender. The domain is verified, and authentication plus the `sign@gxb.vc` envelope sender have been accepted without sending a test message.

Credentials are stored outside Git in `~/.config/sign/smtp.json`, owned by the deploying user with mode 0600. It is a JSON object with `SMTP_USERNAME` and `SMTP_PASSWORD`. `.kamal/secrets` uses `deploy/secret.rb smtp KEY` to load these values into Kamal's secret environment file. Do not run the loader directly or print `kamal config`. `SIGN_SMTP_FILE` can select a different protected file. The source archive contains only the loader and template, never credential values. Tests use fake credentials and check permissions and literal special characters.

To verify authentication from the deployed container without sending mail:

```sh
BUNDLE_GEMFILE=deploy/Gemfile kamal-cli runner deploy/verify_smtp.rb
```

Christian approved the existing queued invitation to `ricky@gxb.vc` on 2026-09-22. Its existing queued job was retried immediately at his request and completed on 2026-09-22. No extra test message or signature request is authorized. Before changing providers or enabling mail again, inspect pending jobs so old messages do not send unexpectedly.

Imported agreements remain drafts. Do not send signature requests or change contract terms without approval. Automated off-server backups must be configured before using the app for executed agreements.

Before upgrading upstream, back up the full volume and test recovery. Select a release whose required upstream CI passes, update `release.json`, and repeat candidate checks. Do not roll back across incompatible database migrations. Containers from before 2026-09-25 used the official image with `/opt/sign/branding/<commit>` host mounts; keep those directories until a rollback to them is no longer needed. Never run `kamal app remove` or remove the persistent volume during redeployment.

## Staff sign-in (GXB SSO)

Staff sign in through https://auth.gxb.vc (OAuth client `sign`, callback `https://sign.gxb.vc/auth/callback`, built from `APP_URL`). The code is `config/initializers/auth_gxb.rb`, `lib/gxb_sso.rb`, `AuthCallbacksController`, and two concerns. When Devise refuses an HTML staff request, the upstream failure app sends it to auth.gxb.vc; API and JSON requests keep their 401. `GET /sign_in` also goes to GXB. Password sign-in is off: `POST /sign_in` never authenticates, Devise `params_authenticatable` is false, the password reset pages (including the link in an upstream invitation email) go to `/sign_in`, and the profile page has no password or two-factor settings. A refused GXB sign-in shows a 403 page with the reason and a "Try again" link (never a redirect to `/sign_in`, which would loop). Public signing pages skip Devise, so they never redirect.

The first GXB sign-in matches `users.auth_uid`, then email, and backfills `auth_uid`. An unknown `@gxb.vc` email becomes an admin in the existing account. Other emails, archived users, `gxbot@gxb.vc`, and an email bound to another GXB subject are refused.

`AUTH_GXB_CLIENT_SECRET` comes from protected `~/.config/sign/auth.json` (JSON key `AUTH_GXB_CLIENT_SECRET`, mode 0600) through `deploy/secret.rb auth AUTH_GXB_CLIENT_SECRET`; `SIGN_AUTH_FILE` can select a different file. If the secret is blank, `/sign_in` shows "GXB sign-in is not configured" (503) and `/auth/callback` refuses. There is no password fallback. If GXB sign-in breaks, fix it and redeploy, or use the production runner.

## Chat tools (GXB Chat host API)

GXB Chat (project `sign`, `tools_endpoint` `/chat_api/tools`) lists tools with `GET /chat_api/tools` and calls one with `POST /chat_api/tools` and JSON `{ tool, arguments }`. Chat shows them as `sign__<name>`. The code is `config/initializers/chat_api.rb` (routes), `ChatApi::ToolsController`, `ChatApiAuthenticatable`, `lib/gxb_chat_tools.rb`, and `lib/gxb_safe_download.rb`.

- Auth: `Authorization: Bearer <CHAT_API_KEY>` (401 if missing, wrong, or if the server key is blank) plus `X-Auth-UID` and/or `X-Auth-Email`. The Sign user is found by `auth_uid`, then email, among active users. Unknown, archived, and `gxbot@gxb.vc` users are 403. A blank `auth_uid` is backfilled; a user bound to another subject is 403 and never rebound. No session or cookie is created.
- Tools: `search_templates`, `load_template`, `create_template`, `send_documents`, `search_documents`. They reuse the upstream MCP schemas and logic but run as the resolved user with DocuSeal's normal `Ability`. DocuSeal's own `/mcp`, its setting, and MCP tokens are not used. Keep Settings → MCP off.
- `send_documents` sends real signature request emails. It has `requires_confirmation: true`, `confirmation_binding: template_id`, and `destructiveHint: true`. In the Chat web UI every send waits for approval (a bound tool never takes "always allow"). Through the GXB connector (mcp.gxb.vc), Chat does not gate host tools: only the MCP client's own prompt for a `destructiveHint` tool stands between the model and the send. Never call it from checks or candidates.
- It refuses an unknown role or more submitters than the template has roles, and returns the submitters it emailed. `create_template` is PDF only (DOCX needs Pro); a failure after the save deletes the partial template. Downloads are https, public addresses only, 20 MB, about 12 s.
- `create_template` takes a name and an optional public https PDF URL. The download refuses non-https URLs, other ports, credentials in the URL, hosts that resolve to private or local addresses, more than 3 redirects, files over 20 MB, downloads over 20 seconds, and non-PDF files.
- Errors are JSON: unknown tool 404, bad arguments 422, a record that is missing or in another account 404.

`CHAT_API_KEY` must equal the Chat project's `api_key`. It comes from protected `~/.config/sign/chat.json` (JSON key `CHAT_API_KEY`, mode 0600) through `deploy/secret.rb chat CHAT_API_KEY`; `SIGN_CHAT_FILE` can select a different file. Candidates get a fake key. Candidate A checks 401, 403, the five tools, and the `send_documents` confirmation flag. Candidate B lists the tools as `christian@gxb.vc` (email only, so nothing is written) and finds the Bailey template with `search_templates`.

## Field guard

Every way of writing fields (editor, REST API, PDF tags, DocuSeal MCP, GXB Chat) ends in `Template#fields` or `Submission#template_fields`, so the checks live on those models: `lib/gxb_field_guard.rb`, `app/models/concerns/gxb_template_fields.rb`, `app/models/concerns/gxb_submission_fields.rb`, included by `config/initializers/field_guard_gxb.rb`. No upstream file changes.

- On every template and submission save, a raw `datenow` field becomes a read-only `date` with default `{{date}}` (what the editor does). Without this, the signing form has no step for it and the signer is stuck (Cameron Davis, 2026-09-30).
- On every template save, a type the signing form cannot show is refused. The list is `GxbFieldGuard::TYPES`; a spec compares it with the editor type list so a new upstream type cannot drift.
- When a submission is created, or its field snapshot changes, these are refused: a required read-only field with no default value, a field whose `submitter_uuid` is not a signer, a select, radio, or multiple field with no options, and duplicate field uuids. Editor drafts still save, because these checks are not on template saves.
- The REST API answers 422 and DocuSeal MCP returns a tool error with the field name, not a 500. GXB Chat already returned 422 for `RecordInvalid`.
- Deploy checks: candidate A proves `datenow` is normalized and the API refuses an unknown type. Candidate B runs every template in the restored backup through the guard; a template with an unknown type stops the deploy, and a template that could not be sent again is printed as `WARN`.
- Raw SQL, `update_column`, and `insert_all` skip model callbacks. The production runner uses `update!`.
