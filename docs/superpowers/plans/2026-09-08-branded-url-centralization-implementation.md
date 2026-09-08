# Branded URL Centralization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `dig.is` (or the configured local/preview host) the single managed origin for branded links, with safe direct-URL fallback and compact canonical ticket slugs.

**Architecture:** Extend `Rails.application.config.x.short_links` with validated protocol, host, and port settings plus a separate `public_app_url` destination. Add `Links::BrandedUrl` as the only URL-construction boundary: it reuses canonical event/organization links, creates or reuses compact canonical ticket links, and falls back to a signed direct ticket URL when branded links are disabled or link persistence fails. The existing `Links::TargetResolver` remains responsible for generating the signed ticket-view destination at resolution time.

**Tech Stack:** Rails 8.1, Active Record, `ActiveSupport::OrderedOptions`, existing `Links::ShortLink`/`Links::Resolve`, signed `Ticketing::GuestTicketViewToken`, Minitest.

---

## File map

- Modify `config/initializers/short_links.rb` — define the single branded-link configuration and public application fallback.
- Modify `config/routes.rb` — make the branded-host constraint honor an optional configured port.
- Create `app/services/links/branded_url.rb` — build branded and direct URLs for ticket, event, organization, and arbitrary short-link slugs.
- Modify `app/services/links/backfill_canonical.rb` — use compact deterministic ticket slugs for canonical rows; development data is reset rather than supported in two slug formats.
- Modify `app/jobs/ticketing/guest_ticket_delivery_job.rb` — call the shared builder instead of constructing a direct URL.
- Create `test/services/links/branded_url_test.rb` — configuration, fallback, compact-slug, reuse, collision, and direct-route tests.
- Modify `test/jobs/links/backfill_canonical_links_job_test.rb` — assert compact ticket slugs and repeatability.
- Modify `test/jobs/ticketing/guest_ticket_delivery_job_test.rb` — verify branded and fallback SMS bodies.
- Modify `test/services/links/resolve_test.rb` and `test/controllers/links/redirects_controller_test.rb` — verify host routing and signed ticket resolution.
- Modify `docs/runbooks/guest-shadow-checkout.md` and `docs/runbooks/messaging-preview-provider.md` — document environment behavior and test limitations.
- Create `app/services/core/phone_verification/preview_sender.rb` and `config/initializers/phone_verification.rb` — provide an explicitly opt-in Render-preview-only OTP debug sender.
- Modify `app/services/messaging/providers/preview_adapter.rb` — optionally log preview SMS bodies without recipient phone numbers.
- Create `test/services/core/phone_verification/preview_sender_test.rb` — verify the preview-only OTP logging guard and output.

### Task 1: Centralize and validate URL configuration

**Files:**
- Modify: `config/initializers/short_links.rb`
- Modify: `config/routes.rb`
- Create: `test/services/links/branded_url_test.rb`
- Modify: `test/controllers/links/redirects_controller_test.rb`

- [x] **Step 1: Write failing tests**

Add tests that replace `Rails.application.config.x.short_links` with `ActiveSupport::OrderedOptions` and assert that `enabled: true`, host `localhost`, protocol `http`, and port `3000` are accepted. Assert that a request with host `localhost` and port `3000` reaches the branded redirect route while another host does not. Invalid protocols, blank hosts, and ports outside `1..65_535` must fail clearly.

- [x] **Step 2: Run the tests and verify RED**

Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/links/branded_url_test.rb test/controllers/links/redirects_controller_test.rb`. Expected: failure because the protocol/port configuration and host constraint do not exist.

- [x] **Step 3: Implement the configuration boundary**

Keep `SHORT_LINKS_ENABLED` defaulting to `false`. Add `SHORT_LINKS_HOST`, `SHORT_LINKS_PROTOCOL`, and `SHORT_LINKS_PORT`; validate the protocol and port during initialization, and normalize a configured port to an integer. Add `Rails.application.config.x.public_app_url` from `PUBLIC_APP_URL`, defaulting to `http://localhost:3000` in development/test and requiring an explicit non-blank value in production. Update the route constraint to compare `request.host` with the configured host and compare `request.port` as an integer only when a port is configured:

```ruby
configured_port = config.port.presence
request.host == config.host &&
  (configured_port.blank? || request.port == configured_port.to_i)
```

When the configured port is blank, do not compare ports so standard production HTTP/HTTPS ports remain accepted. A production boot with no `PUBLIC_APP_URL` must fail with a clear configuration error rather than inventing an application domain.

- [x] **Step 4: Run the tests; commit remains a manual handoff**

Run the command from Step 2, then commit the configuration boundary with:

```bash
git add config/initializers/short_links.rb config/routes.rb test/services/links/branded_url_test.rb test/controllers/links/redirects_controller_test.rb
git commit -m "feat: centralize branded link configuration"
```

### Task 2: Implement the shared URL builder

**Files:**
- Create: `app/services/links/branded_url.rb`
- Modify: `app/services/links/backfill_canonical.rb`
- Modify: `test/services/links/branded_url_test.rb`
- Modify: `test/jobs/links/backfill_canonical_links_job_test.rb`

- [x] **Step 1: Write failing behavior tests**

Cover these exact contracts:

- `short_url("summer-festival")` joins the configured origin and slug once.
- Disabled branded links return a signed direct ticket URL under `public_app_url`.
- Enabled ticket links create or reuse exactly one canonical `Links::ShortLink` and use a slug matching `\At-[a-z0-9]{6}\z`.
- New backfill-created ticket links use the same compact `t-` shape. Because this project has no live users, development rows are reset/recreated; no legacy ticket-slug compatibility branch is added.
- Five or fewer slug-collision retries are attempted; exhaustion falls back to the direct URL.
- Existing canonical event and organization links are reused; absent links use `/public/events/:slug` and `/organizations/:id` under `public_app_url`.
- Branded-link persistence errors fall back without logging a signed token.

- [x] **Step 2: Run the tests and verify RED**

Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/links/branded_url_test.rb`. Expected: failure because the service does not exist.

- [x] **Step 3: Implement `Links::BrandedUrl`**

Expose exactly:

```ruby
Links::BrandedUrl.base_url
Links::BrandedUrl.short_url(slug)
Links::BrandedUrl.ticket(ticket)
Links::BrandedUrl.event(event)
Links::BrandedUrl.organization(organization)
```

Use the configured branded origin, never a hardcoded `dig.is`. For tickets, insert the canonical `(target_type: "ticket", target_id: ticket.id, canonical: true)` row and, after a unique violation, perform one canonical-target recheck before retrying slug generation; assign `t-` plus six lowercase alphanumeric characters only on creation, and retry slug collisions no more than five times. Update `Links::BackfillCanonical` so newly created ticket rows use a deterministic six-character digest-derived suffix. Do not add a branch for old long ticket slugs; reset/recreate development rows when the new format is introduced. Rescue only the known Active Record/argument/Core errors around branded creation and return the signed direct URL. Call `Ticketing::GuestTicketViewToken.issue` only for direct fallback; the short-link row must contain no bearer token.

- [x] **Step 4: Run the tests; commit remains a manual handoff**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/links/branded_url_test.rb
git add app/services/links/branded_url.rb test/services/links/branded_url_test.rb
git add app/services/links/backfill_canonical.rb test/jobs/links/backfill_canonical_links_job_test.rb
git commit -m "feat: add centralized branded URL builder"
```

### Task 3: Integrate guest delivery and signed resolution

**Files:**
- Modify: `app/jobs/ticketing/guest_ticket_delivery_job.rb`
- Modify: `test/jobs/ticketing/guest_ticket_delivery_job_test.rb`
- Modify: `test/services/links/resolve_test.rb`
- Modify: `test/controllers/links/redirects_controller_test.rb`

- [x] **Step 1: Write failing integration tests**

With branded configuration enabled, assert the guest SMS body contains `http://localhost:3000/t-[a-z0-9]{6}`. With it disabled, assert the body contains `/public/tickets/:id?view_token=`. Resolve the canonical ticket slug and assert the destination contains the correct ticket ID and a signed `view_token`; the slug alone must not authorize a ticket. Keep the existing disabled-link redirect fallback test because it is an intentional operational resilience behavior, not support for an old data format.

- [x] **Step 2: Run the tests and verify RED**

Run:

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/ticketing/guest_ticket_delivery_job_test.rb test/services/links/resolve_test.rb test/controllers/links/redirects_controller_test.rb
```

Expected: the delivery test still sees the old direct URL because the job bypasses `Links::BrandedUrl`.

- [x] **Step 3: Use the shared builder from the job**

Replace the job’s URL assembly with:

```ruby
def message_for(ticket)
  "Your ticket for #{ticket.event.title} is ready: #{Links::BrandedUrl.ticket(ticket)}"
end
```

Keep the existing event eager preload, SMS adapter idempotency key, and retry behavior.

- [x] **Step 4: Run the tests; commit remains a manual handoff**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/ticketing/guest_ticket_delivery_job_test.rb test/services/links/resolve_test.rb test/controllers/links/redirects_controller_test.rb
git add app/jobs/ticketing/guest_ticket_delivery_job.rb test/jobs/ticketing/guest_ticket_delivery_job_test.rb test/services/links/resolve_test.rb test/controllers/links/redirects_controller_test.rb
git commit -m "feat: deliver guest tickets through branded links"
```

### Task 4: Document and verify operations

**Files:**
- Modify: `docs/runbooks/guest-shadow-checkout.md`
- Modify: `docs/runbooks/messaging-preview-provider.md`

- [x] **Step 1: Document configuration**

Document these exact values:

| Environment | `SHORT_LINKS_ENABLED` | `SHORT_LINKS_HOST` | `SHORT_LINKS_PROTOCOL` | `SHORT_LINKS_PORT` | `PUBLIC_APP_URL` |
| --- | --- | --- | --- | --- | --- |
| Local | `true` for redirect tests | `localhost` | `http` | `3000` | `http://localhost:3000` |
| Render preview | `true` for branded-link tests | preview hostname | `https` | blank | preview application URL |
| Production | `true` | `dig.is` | `https` | blank | explicit application URL (`PUBLIC_APP_URL`); do not rely on a default |

State explicitly that disabling branded links is a manual switch, not automatic DNS-outage detection; existing branded slugs continue through the deliberate normal-route fallback; production requires an explicit `PUBLIC_APP_URL`; and preview delivery simulates outcomes without sending SMS.

- [x] **Step 2: Keep Postman examples host-neutral**

Do not add a new endpoint. Keep `{{baseUrl}}` in the existing public-ticket examples and never add a real signed token to the collection.

- [x] **Step 3: Run the complete gates**

```bash
N_PLUS_ONE=1 PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/links test/controllers/links test/jobs/ticketing/guest_ticket_delivery_job_test.rb test/services/core/phone_verification_test.rb test/integration/orders/guest_checkout_test.rb test/integration/ticketing/public_ticket_views_test.rb
RUBOCOP_CACHE_ROOT=/private/tmp/digis-rubocop-cache PATH="$HOME/.asdf/shims:$PATH" bundle exec rubocop
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails zeitwerk:check
PATH="$HOME/.asdf/shims:$PATH" bundle exec brakeman -q
python3 -m json.tool 'postman/Digis API_collection.json' >/dev/null
git diff --check
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test
```

Expected: focused and full tests pass, RuboCop reports no offenses, Zeitwerk reports `All is good!`, Brakeman reports zero warnings, Postman JSON parses, and `git diff --check` is clean.

- [ ] **Step 4: Commit documentation**

```bash
git add docs/runbooks/guest-shadow-checkout.md docs/runbooks/messaging-preview-provider.md
git commit -m "docs: document branded link operations"
```

### Task 5: Add safe preview-only OTP/SMS observability

**Files:**
- Create: `app/services/core/phone_verification/preview_sender.rb`
- Create: `config/initializers/phone_verification.rb`
- Modify: `app/services/messaging/providers/preview_adapter.rb`
- Create: `test/services/core/phone_verification/preview_sender_test.rb`
- Modify: `test/services/messaging/providers/preview_adapter_test.rb`
- Modify: `docs/runbooks/guest-shadow-checkout.md`
- Modify: `docs/runbooks/messaging-preview-provider.md`

- [x] **Step 1: Write failing tests**

Assert that `DIGIS_PREVIEW_DEBUG_LOGGING=true` is rejected unless `RENDER_PREVIEW=true`. When both flags are true, the injected phone-verification sender logs the challenge ID and six-digit code, never the phone number, and returns success. Assert that the preview SMS adapter logs the message body only with the same guarded flag and never logs the recipient phone. With the flag absent, neither path logs message content.

- [x] **Step 2: Run the tests and verify RED**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/core/phone_verification/preview_sender_test.rb \
  test/services/messaging/providers/preview_adapter_test.rb
```

Expected: failure because the preview sender, initializer guard, and debug logging do not exist.

- [x] **Step 3: Implement explicit preview-only visibility**

Register `Core::PhoneVerification::PreviewSender` from `config/initializers/phone_verification.rb` only when both `RENDER_PREVIEW=true` and `DIGIS_PREVIEW_DEBUG_LOGGING=true`. Raise a clear boot error if the debug flag is set outside a Render preview. The sender logs only `challenge_id` and the OTP code to the preview logger and never logs phone numbers. Update `Messaging::Providers::PreviewAdapter#deliver_sms` to log the SMS body only under the same two-flag guard; do not log recipient phone numbers. Keep the default sender unset and the default behavior fail-closed.

- [ ] **Step 4: Run the tests and commit**

```bash
PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test \
  test/services/core/phone_verification/preview_sender_test.rb \
  test/services/messaging/providers/preview_adapter_test.rb
git add app/services/core/phone_verification/preview_sender.rb \
  config/initializers/phone_verification.rb \
  app/services/messaging/providers/preview_adapter.rb \
  test/services/core/phone_verification/preview_sender_test.rb \
  test/services/messaging/providers/preview_adapter_test.rb
git commit -m "feat: add opt-in preview OTP observability"
```

- [x] **Step 5: Document the safety boundary**

Document `DIGIS_PREVIEW_DEBUG_LOGGING=true` as a temporary private-preview setting that exposes OTP codes and SMS bodies in Render logs for frontend testing. It must be disabled immediately after testing and must never be set on a live production service. Use branded links in preview (`SHORT_LINKS_ENABLED=true`) when inspecting SMS bodies so logs contain a short URL rather than a signed direct bearer URL.

## Explicit non-goals

- Do not default branded links to enabled.
- Do not create a DNS, Cloudflare, or separate short-link service.
- Do not store signed ticket-view tokens in `links_short_links`.
- Do not claim that compact URLs alone guarantee one SMS segment; GSM-7/UCS-2 message length still applies.
- Do not add frontend routes in this backend plan; `PUBLIC_APP_URL` must point to a host serving or proxying the existing public-ticket route.
