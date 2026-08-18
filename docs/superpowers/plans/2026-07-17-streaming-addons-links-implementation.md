# Streaming Add-ons and Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add secure live/replay access, composable included and separately purchased add-ons, parking admission, organizer reporting, and optional branded links without parallel commerce or credential systems.

**Architecture:** Streaming and parking are product-access channels on credential-bearing packages; merchandise, food, donations, and digital add-ons use existing catalog/order/inventory fulfillment. Included rights move with the ticket package while separate add-on packages retain their owner. Branded links are feature-gated redirects, never credentials or authorization.

**Tech Stack:** Rails 8.1 API-only, Ruby 3.4, PostgreSQL UUIDs/checks/advisory locks/partial indexes, Pundit, ActiveModelSerializers, Solid Queue, encrypted attributes/Rails credentials, Minitest fixtures.

---

**Authoritative specifications:**

- `docs/COMPOSABLE_EVENT_PLATFORM_DATABASE_DESIGN.md`
- `docs/TICKET QR CODE AND OFFLINE SCANNING ARCHITECTURE v3.md`

**Prerequisites:** Complete core foundation and package credential validation; parking scanning also requires the scanner plan. Services use typed `Core::BusinessError` with inherited `success`/`failure`; reuse outbox/audit/idempotency/advisory locks.

**Composition contract:** ticket-product venue/stream/parking accesses follow one package owner/generation; separately purchased parking/digital add-ons remain separate packages/order items; merchandise/food/donation receive no credential absent an approved access; stream tokens and short links are never QR/PNR.

## Task 1: Create playback-session schema on the existing event-stream model

**Files:**
- Create: `db/migrate/20260818090001_create_ticketing_stream_sessions.rb`
- Reuse: `app/models/events/event_stream.rb`
- Create: `app/models/ticketing/stream_session.rb`
- Test: `test/models/ticketing/stream_session_test.rb`
- Test data is created dynamically because this repository has no event-date or
  event-stream fixtures; stream-session rows remain runtime authorization data
  and are intentionally not seeded.

- [x] **Step 1: RED — test unique token digest and lifecycle checks**

The test setup creates a valid event stream and ticket dynamically, then
asserts that duplicate token digests are rejected and revoked sessions require
`revoked_at`.

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/stream_session_test.rb`

Verified RED: 2 tests errored with `NameError: uninitialized constant
Ticketing::StreamSession`, because the model did not exist yet.

- [x] **Step 3: GREEN — create only `ticketing_stream_sessions`**

Reuse the event-foundation plan's `events_event_streams` table and model. Create ticket, event stream, user, normalized device ID, unique token digest, active/expired/revoked status, expiry/last-seen/revoked times.

The migration uses `20260818090001` rather than the plan's original historical
date so the ticket and event-stream foreign-key targets already exist on a
fresh install; this follows the repository's dependency-ordered migration
convention.

```ruby
add_index :ticketing_stream_sessions, :session_token_digest, unique: true
add_index :ticketing_stream_sessions, %i[ticket_id event_stream_id status expires_at],
  name: "idx_stream_session_authorization"
```

Add status/time and expiry checks plus a deferred same-event ticket/stream FK trigger. Provider identifiers remain protected and secrets remain in Rails credentials/encrypted fields, never stream config or serializers.

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:migrate && PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/models/ticketing/stream_session_test.rb`

Verified: 3 tests, 4 assertions, 0 failures, 0 errors with `N_PLUS_ONE=1`,
including the cross-event database guard. The fresh checked-in SQL structure
also loads successfully with `db:test:prepare`.

- [x] **Step 5: REFACTOR — keep provider behavior out of models**

Models retain associations, validations, lifecycle predicates, and scopes only;
provider behavior and plaintext session tokens are absent. Zeitwerk and targeted
RuboCop checks pass.

- [ ] **Step 6: Commit — user-owned**

```bash
git add db/migrate/20260818090001_create_ticketing_stream_sessions.rb db/structure.sql app/models/core/user.rb app/models/events/event_stream.rb app/models/ticketing/ticket.rb app/models/ticketing/stream_session.rb test/models/ticketing/stream_session_test.rb
git commit -m "feat(streaming): add playback sessions"
```

## Task 2: Authorize short-lived live and replay sessions

**Files:**
- Create: `app/services/streaming/sessions/create.rb`
- Create: `app/services/streaming/sessions/refresh.rb`
- Create: `app/services/streaming/sessions/revoke.rb`
- Create: `app/services/streaming/authorization.rb`
- Create: `app/values/streaming/playback_grant.rb`
- Create: `app/values/streaming/window.rb`
- Create: `app/services/streaming/providers/error.rb`, `unknown_provider.rb`, `invalid_configuration.rb`, `playback_unavailable.rb`
- Create: `app/services/streaming/providers/base_adapter.rb`
- Create: `app/services/streaming/providers/youtube_adapter.rb`
- Create: `app/services/streaming/providers/registry.rb`
- Create: `config/initializers/streaming.rb`
- Create: `app/controllers/ticketing/stream_sessions_controller.rb`
- Create: `app/policies/ticketing/stream_session_policy.rb`
- Create: `app/serializers/ticketing/stream_session_serializer.rb`
- Modify: `app/services/events/publication_readiness.rb`
- Modify: `app/serializers/catalog/product_quote_serializer.rb`
- Modify: `config/routes.rb`
- Modify: `config/locales/streaming.en.yml`, `config/initializers/inflections.rb`, and `postman/Digis API_collection.json`
- Create: `test/support/fakes/streaming/fake_adapter.rb`
- Create: `test/support/contracts/streaming/provider_adapter_contract.rb`
- Create: `test/services/streaming/providers/youtube_adapter_test.rb`
- Create: `test/services/streaming/providers/fake_adapter_test.rb`
- Create: `test/services/streaming/providers/registry_test.rb`
- Test: `test/services/streaming/sessions/create_test.rb`
- Test: `test/services/streaming/sessions/refresh_test.rb`
- Test: `test/services/events/publication_readiness_streaming_test.rb`
- Test: `test/controllers/ticketing/stream_sessions_controller_test.rb`
- Test: `test/serializers/catalog/product_quote_streaming_test.rb`
- Test support: `test/support/streaming_test_helpers.rb`

- [x] **Step 1: RED — specify authorization, provider contract, and honest protection disclosure**

```ruby
test "creates one short-lived session for an authorized current holder" do
  ticket = ticketing_tickets(:hybrid_friday)
  result = Streaming::Sessions::Create.call(
    ticket:, event_stream: events_event_streams(:festival_friday),
    user: ticket.owner_user, device_id: "ios:9f0f6af3", now: Time.current,
    idempotency_key: "stream:#{ticket.id}:ios:9f0f6af3"
  )
  assert result.success?
  assert_equal "active", result.value.session.status
  assert result.value.session_token.present?
  assert_not_equal result.value.session_token, result.value.session.session_token_digest
  assert_equal "youtube", result.value.playback_grant.provider
  assert_equal "embed", result.value.playback_grant.playback_type
  assert_equal events_event_streams(:festival_friday).provider_playback_id,
    result.value.playback_grant.embed_id
  assert_nil result.value.playback_grant.token
end
```

Also cover wrong date/event, venue-only, replay disabled/expired, transferred/delegated-away holder, suspended/refunded ticket, old generation, simultaneous device-limit race, disabled/unknown provider, missing YouTube playback ID, requested `signed` protection with YouTube, and grant expiry never exceeding either the Digis session or authorized live/replay window.

The provider contract suite must run against `YouTubeAdapter` and the test-only `FakeAdapter`. Publication tests prove:

- paid `soft_gated` YouTube access is allowed and emits `soft_gated_youtube_link_sharing` in product/checkout presentation;
- a stream access requiring `signed` cannot publish through YouTube;
- a provider change cannot fall below a frozen or sold product-access requirement;
- no stream can claim `internal`, self-hosted, signed, non-shareable, or provider-enforced playback without a registered adapter that actually supports it.

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/streaming test/services/events/publication_readiness_streaming_test.rb test/controllers/ticketing/stream_sessions_controller_test.rb`

Verified RED after the test loader was corrected: 17 tests, 3 assertions,
1 expected publication/controller failure, and 15 missing-implementation
errors.

- [x] **Step 3: GREEN — define immutable provider-neutral values and adapter contract**

```ruby
# frozen_string_literal: true

module Streaming
  PlaybackGrant = Data.define(
    :provider,
    :playback_type,
    :playback_url,
    :embed_id,
    :token,
    :expires_at
  ) do
    PLAYBACK_TYPES = %w[embed hls url].freeze

    def initialize(provider:, playback_type:, playback_url:, embed_id:, token:, expires_at:)
      fail ArgumentError, "provider is required" if provider.blank?
      fail ArgumentError, "unsupported playback type" unless PLAYBACK_TYPES.include?(playback_type)
      fail ArgumentError, "expires_at is required" if expires_at.nil?
      fail ArgumentError, "embed playback requires embed_id" if playback_type == "embed" && embed_id.blank?
      fail ArgumentError, "URL playback requires playback_url" if playback_type != "embed" && playback_url.blank?

      super
    end
  end

  Window = Data.define(:opens_at, :closes_at, :replay) do
    def initialize(opens_at:, closes_at:, replay:)
      fail ArgumentError, "window must close after it opens" unless opens_at < closes_at

      super(opens_at:, closes_at:, replay: !!replay)
    end

    def replay? = replay
  end
end
```

```ruby
# frozen_string_literal: true

module Streaming
  module Providers
    class Error < Core::Error; end
    class UnknownProvider < Error; end
    class InvalidConfiguration < Error; end
    class PlaybackUnavailable < Error; end

    class BaseAdapter
      def playback_grant(session:, window:)
        fail NotImplementedError, "#{self.class.name} must implement #playback_grant"
      end

      def revoke_playback(session:)
        fail NotImplementedError, "#{self.class.name} must implement #revoke_playback"
      end

      def supported_access_protections
        fail NotImplementedError, "#{self.class.name} must implement #supported_access_protections"
      end

      def validate_configuration!(event_stream)
        return if supported_access_protections.include?(event_stream.access_protection)

        fail InvalidConfiguration,
          "#{event_stream.provider} cannot provide #{event_stream.access_protection} playback"
      end
    end
  end
end
```

The hot-path adapter contract is local and deterministic: it creates an embed configuration or cryptographically signed grant without a provider network call. Provider provisioning, broadcast creation, and status synchronization are separate commands/jobs. Adapters receive an already-authorized session and window; they never decide ticket ownership, product access, refunds, transfer state, or replay eligibility.

The shared contract is executable test support, not documentation-only convention:

```ruby
# frozen_string_literal: true

module Streaming::ProviderAdapterContract
  extend ActiveSupport::Concern

  included do
    test "returns a bounded provider-neutral playback grant" do
      grant = adapter_under_test.playback_grant(session: stream_session, window: stream_window)

      assert_instance_of Streaming::PlaybackGrant, grant
      assert_includes adapter_under_test.supported_access_protections,
        stream_session.event_stream.access_protection
      assert_operator grant.expires_at, :<=, stream_session.expires_at
      assert_operator grant.expires_at, :<=, stream_window.closes_at
    end

    test "revocation is retry safe" do
      first = adapter_under_test.revoke_playback(session: stream_session)
      second = adapter_under_test.revoke_playback(session: stream_session)

      assert_equal first, second
    end
  end

  private

  def adapter_under_test = raise(NotImplementedError)
  def stream_session = raise(NotImplementedError)
  def stream_window = raise(NotImplementedError)
end
```

`YouTubeAdapterTest` and `FakeAdapterTest` include this contract and provide those three fixtures/helpers. Adapter-specific tests still cover missing identifiers, supported protection tiers, token absence for YouTube, and configuration rejection.

- [x] **Step 4: GREEN — implement YouTube, registry, and test fake**

```ruby
# frozen_string_literal: true

module Streaming
  module Providers
    class YouTubeAdapter < BaseAdapter
      SUPPORTED_ACCESS_PROTECTIONS = %w[public soft_gated].freeze

      def playback_grant(session:, window:)
        event_stream = session.event_stream
        validate_configuration!(event_stream)
        video_id = event_stream.provider_playback_id
        fail PlaybackUnavailable, "YouTube playback ID is missing" if video_id.blank?

        Streaming::PlaybackGrant.new(
          provider: "youtube",
          playback_type: "embed",
          playback_url: nil,
          embed_id: video_id,
          token: nil,
          expires_at: [window.closes_at, session.expires_at].min
        )
      end

      def revoke_playback(session:)
        true
      end

      def supported_access_protections = SUPPORTED_ACCESS_PROTECTIONS
    end
  end
end
```

`YouTubeAdapter#revoke_playback` is intentionally provider-side no-op behavior. Digis stops future rendering, refresh, and authorization from its authoritative session/ticket state, but it cannot invalidate a YouTube identifier already extracted from an unlisted embed. The organizer and buyer disclosure must state this limitation. The launch adapter accepts a manually configured YouTube video/broadcast ID; OAuth broadcast provisioning is not required for the first release. A paid `soft_gated` setup must use an unlisted broadcast. Publication verifies privacy when OAuth authorization is available, or records the organizer's explicit confirmation for a manual ID; it never represents that confirmation as provider-enforced protection. The YouTube config validator allowlists only `privacy_status`, `privacy_evidence`, and `privacy_checked_at`; it rejects unknown keys and never stores OAuth/provider secrets in JSON.

```ruby
# frozen_string_literal: true

module Streaming
  module Providers
    class Registry
      HANDLERS = {
        "youtube" => YouTubeAdapter
      }.freeze

      def self.fetch(provider)
        key = provider.to_s
        fail UnknownProvider, "unsupported streaming provider: #{key}" unless HANDLERS.key?(key)
        fail UnknownProvider, "disabled streaming provider: #{key}" unless enabled_provider_keys.include?(key)

        HANDLERS.fetch(key).new
      end

      def self.for(event_stream)
        fetch(event_stream.provider).tap { |adapter| adapter.validate_configuration!(event_stream) }
      end

      def self.enabled_provider_keys
        Array(Rails.application.config.x.streaming.enabled_providers).map(&:to_s)
      end

      private_class_method :enabled_provider_keys
    end
  end
end
```

Configure `Rails.application.config.x.streaming.enabled_providers` from `STREAMING_ENABLED_PROVIDERS`, defaulting to `youtube` in development/test. Production must set it explicitly. Define `Streaming::Fakes::FakeAdapter` only under `test/support`; inject a registry into session commands rather than adding `fake` to the production registry. A future `MuxAdapter` registers another key and supports `signed` without a database migration. Do not add `InternalAdapter`, `SelfHostedHlsAdapter`, storage/origin/CDN/transcoding assumptions, or commented production registry entries.

`config/initializers/streaming.rb` sets only the allowlist; provider secrets stay in Rails credentials (DB design line 881):

```ruby
# config/initializers/streaming.rb
# frozen_string_literal: true

Rails.application.config.x.streaming.enabled_providers =
  ENV.fetch("STREAMING_ENABLED_PROVIDERS", "youtube").split(",").map(&:strip).reject(&:empty?)
```

Never read provider OAuth tokens, playback keys, or unlisted-broadcast credentials from `ENV` or this file; those live in encrypted credentials and are decrypted only inside the relevant adapter at call time.

- [x] **Step 5: GREEN — authorize under ticket/stream advisory lock and return separate tokens**

```ruby
# frozen_string_literal: true

module Streaming
  module Sessions
    class Create < Core::BaseService
      ResultValue = Data.define(:session, :session_token, :playback_grant)

      def initialize(ticket:, event_stream:, user:, device_id:, now:, idempotency_key:,
        provider_registry: Streaming::Providers::Registry)
        @ticket, @event_stream, @user = ticket, event_stream, user
        @device_id, @now = device_id, now
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
        @provider_registry = provider_registry
      end

      def call
        Ticketing::StreamSession.transaction do
          ticket = Ticketing::Ticket.lock.find(@ticket.id)
          stream = Events::EventStream.lock.find(@event_stream.id)
          authorization = Streaming::Authorization.call(ticket:, event_stream: stream, user: @user, now: @now)
          return authorization if authorization.failure?
          lock_device_scope!(ticket, stream)
          verification = verify_device_limit(ticket, stream)
          return verification if verification.failure?
          session_token = SecureRandom.urlsafe_base64(48)
          session = Ticketing::StreamSession.create!(
            ticket:, event_stream: stream, user: @user,
            device_id: normalize_device_id(@device_id), session_token_digest: digest(session_token),
            status: "active", expires_at: [@now + 10.minutes, authorization.value.window_closes_at].min
          )
          window = Streaming::Window.new(
            opens_at: authorization.value.window_opens_at,
            closes_at: authorization.value.window_closes_at,
            replay: authorization.value.replay?
          )
          adapter = @provider_registry.for(stream)
          playback_grant = adapter.playback_grant(session:, window:)
          success(ResultValue.new(session:, session_token:, playback_grant:))
        end
      rescue Streaming::Providers::Error => error
        failure Core::BusinessError.new(
          "Streaming playback is unavailable",
          code: "streaming_playback_unavailable",
          status: :unprocessable_entity,
          meta: { provider: @event_stream.provider, reason: error.class.name }
        )
      end
    end
  end
end
```

Authorization requires an active ticket, current active credential held by requester, matching stream access/date, and open live/replay window. Serialize concurrent-device counting with transaction advisory lock `(ticket_id,event_stream_id)`. Store only the Digis session-token digest. The `session_token` plaintext is returned only on session creation and authenticates refresh/heartbeat calls; `playback_grant` contains provider playback material. They are deliberately different concepts.

- [x] **Step 6: GREEN — enforce publication compatibility and checkout disclosure**

`Events::PublicationReadiness` compares every stream access's immutable `required_access_protection` with the configured stream's provider-validated `access_protection`, using `public < soft_gated < signed`. It rejects unsupported/disabled adapters, any insufficient pairing, and any signed/non-shareable claim backed by YouTube. A provider change locks the event stream, checks every frozen/sold access requirement, revokes active Digis stream sessions through outbox work, and only then activates the new configuration.

`Catalog::ProductQuoteSerializer` exposes `stream_access_protection` plus a stable notice code. Paid YouTube products return `soft_gated_youtube_link_sharing`; public streams return `public_stream`; signed providers later return `signed_provider_enforced`. Public/event serializers may expose provider name and protection tier only after publication, but never unpublished playback IDs, session tokens, token digests, or provider credentials.

- [x] **Step 7: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/streaming test/services/events/publication_readiness_streaming_test.rb test/controllers/ticketing/stream_sessions_controller_test.rb`

Verified focused Task 2 suite: 21 tests, 75 assertions, 0 failures, and
0 errors with `N_PLUS_ONE=1`; the locale contract suite adds two more passing
tests. The final full suite passes 2,634 tests and 10,878 assertions with zero
failures and zero errors under `N_PLUS_ONE=1`.

- [x] **Step 8: REFACTOR — keep provider capabilities explicit**

Controller remains `Ticketing::StreamSessionsController` and renders through existing JSON helpers and AMS. Keep `/api/v1` in routes rather than Ruby namespaces. Do not add a generic capability engine: the adapter's explicit protection allowlist and the product access's required tier are sufficient. Mux or Cloudflare Stream becomes a later adapter plus contract tests, not a new ticket/session schema.

- [ ] **Step 9: Commit — user-owned**

```bash
git add app/controllers/catalog/product_quotes_controller.rb app/controllers/ticketing/stream_sessions_controller.rb app/models/ticketing/stream_session.rb app/policies/ticketing/stream_session_policy.rb app/serializers/catalog/product_quote_serializer.rb app/serializers/ticketing/stream_session_serializer.rb app/services/events/publication_readiness.rb app/services/streaming app/values/streaming config/initializers/inflections.rb config/initializers/streaming.rb config/locales/streaming.en.yml config/routes.rb db/migrate/20260818090001_create_ticketing_stream_sessions.rb db/structure.sql postman/'Digis API_collection.json' test/controllers/ticketing/stream_sessions_controller_test.rb test/serializers/catalog/product_quote_streaming_test.rb test/services/events/publication_readiness_streaming_test.rb test/services/streaming test/support/contracts/streaming test/support/fakes/streaming test/support/streaming_test_helpers.rb
git commit -m "feat(streaming): add honest YouTube playback adapter"
```

## Task 3: Revoke streaming authority on ticket/event lifecycle changes

**Files:**
- Create: `app/jobs/streaming/expire_sessions_job.rb`
- Create: `app/jobs/streaming/revoke_ticket_sessions_job.rb`
- Create: `app/services/streaming/outbox_handlers/revoke_ticket_sessions.rb`
- Create: `config/initializers/streaming_outbox_handlers.rb`
- Modify: `config/initializers/events_outbox_handlers.rb`
- Modify: `config/initializers/ticketing_outbox_handlers.rb`
- Modify: `config/recurring.yml`
- Reuse: `app/jobs/core/dispatch_outbox_event_job.rb`
- Test: `test/jobs/streaming/expire_sessions_job_test.rb`
- Test: `test/integration/streaming/ticket_lifecycle_test.rb`

- [x] **Step 1: RED — cover every lifecycle producer**

Test transfer, delegation away, suspension, refund, event/date cancellation, replay expiry, resale reservation, and generation replacement. New authorization fails immediately from DB state; already issued sessions close idempotently.

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/streaming test/integration/streaming/ticket_lifecycle_test.rb`

Expected: FAIL because handlers/jobs are missing.

- [x] **Step 3: GREEN — register outbox handlers and bounded jobs**

Register `Streaming::OutboxHandlers::RevokeTicketSessions` for approved lifecycle types. It enqueues with the outbox idempotency key. Job locks active sessions, marks revoked once, then calls the registered provider adapter idempotently after authoritative state changes. Expiry uses `FOR UPDATE SKIP LOCKED` batches and never extends tokens. Never call providers inside ticket transactions.

For YouTube, adapter revocation is deliberately a successful no-op: the revoked Digis session can no longer refresh or receive playback configuration, but a viewer who already copied the unlisted YouTube identifier may still use it. Tests must prove both sides of that contract. Future signed providers must invalidate or expire their provider grant according to their adapter contract.

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/streaming test/integration/streaming/ticket_lifecycle_test.rb`

Verified focused Task 3 suite: 8 tests, 51 assertions, 0 failures, and 0
errors with `N_PLUS_ONE=1`.

The final full suite passes 2,642 tests and 10,930 assertions with zero
failures and zero errors under `N_PLUS_ONE=1`.

- [x] **Step 5: REFACTOR — keep lifecycle truth in ticket/event records**

Provider cleanup failure cannot make an invalid ticket authorize playback.

The existing event and ticketing outbox handlers are composed in place, while
the new streaming initializer owns only lifecycle event types with no existing
domain handler. Local session revocation commits before provider cleanup, and
the bounded workers use `FOR UPDATE SKIP LOCKED` without extending expiry.
`Streaming::ExpireSessionsJob` is scheduled every minute on the streaming queue
so expired local sessions are closed even when no refresh request arrives.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/jobs/streaming app/services/streaming/outbox_handlers config/initializers/events_outbox_handlers.rb config/initializers/streaming_outbox_handlers.rb config/initializers/ticketing_outbox_handlers.rb config/locales/streaming.en.yml config/recurring.yml test/jobs/streaming test/integration/streaming docs/superpowers/plans/2026-07-17-streaming-addons-links-implementation.md
git commit -m "feat(streaming): revoke sessions on lifecycle changes"
```

## Task 4: Fulfill typed add-ons through existing order items

**Files:**
- Create: `app/services/catalog/add_ons/validate_product.rb`
- Create: `app/services/orders/fulfillment/fulfill_add_on.rb`
- Create: `app/services/orders/fulfillment/add_on_registry.rb`
- Create: `app/services/orders/fulfillment/merchandise.rb`
- Create: `app/services/orders/fulfillment/food.rb`
- Create: `app/services/orders/fulfillment/donation.rb`
- Create: `app/services/orders/fulfillment/digital_add_on.rb`
- Create: `config/locales/catalog/add_ons.en.yml`
- Create: `config/locales/orders/fulfillment.en.yml`
- Test: `test/services/catalog/add_ons/validate_product_test.rb`
- Test: `test/services/orders/fulfillment/fulfill_add_on_test.rb`
- Test data is created dynamically because this repository has no order-item
  fixtures and add-on fulfillment rows are runtime order state.

- [x] **Step 1: RED — specify supported types and retry-safe order-item fulfillment**

Cover parking, merchandise, food, donation, digital add-on, other; custom
donation price; inventory race; immutable whole-item quantity after payment;
retry returning the same fulfilled order item; and noncredential products never
receiving QR.

```ruby
test "retry returns the fulfilled order item without another side effect" do
  item = create_paid_add_on_item(type: "merchandise")
  first = Orders::Fulfillment::FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")
  second = Orders::Fulfillment::FulfillAddOn.call(order_item: item, idempotency_key: "addon:#{item.id}")
  assert first.success?
  assert_equal item.id, first.value.id
  assert_equal first.value.id, second.value.id
  assert first.value.reload.fulfilled?
end
```

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/add_ons test/services/orders/fulfillment/fulfill_add_on_test.rb`

Verified RED after correcting the dynamic paid-order setup: 10 tests, 0
assertions, 0 failures, and 10 expected missing-implementation errors.

- [x] **Step 3: GREEN — dispatch explicit handlers and return the order item**

```ruby
module Orders
  module Fulfillment
    class AddOnRegistry
      HANDLERS = {
        "merchandise" => Merchandise,
        "food" => Food,
        "donation" => Donation,
        "digital_addon" => DigitalAddOn
      }.freeze

      def self.fetch(type)
        HANDLERS[type.to_s]
      end
    end

    class FulfillAddOn < Core::BaseService
      def initialize(order_item:, idempotency_key:)
        @order_item = order_item
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        ActiveRecord::Base.transaction do
          item = Orders::OrderItem.includes(:order, :event_product).lock.find(@order_item.id)
          return success(item) if item.fulfilled?
          return failure(error(:item_not_pending)) unless item.fulfillment_status == "pending"
          return failure(error(:order_not_paid)) unless item.order.paid?

          validation = Catalog::AddOns::ValidateProduct.call(product: item.event_product)
          return failure(validation.error) if validation.failure?

          handler = AddOnRegistry.fetch(item.event_product.type)
          return failure(error(:unsupported_add_on_type)) unless handler

          result = handler.call(order_item: item, idempotency_key: @idempotency_key.to_s)
          return result if result.failure?

          item.update!(fulfillment_status: "fulfilled")
          success(item)
        end
      end
    end
  end
end
```

There is no invented generic fulfillment association/table, fulfilled timestamp,
or partial-quantity counter. The existing `fulfillment_status` on the immutable
order item is the command result and whole-item idempotency boundary. The
command requires a paid order and pending item, then locks the item, dispatches
an explicit handler, and marks only that status. Parking is absent because Task
5 uses package issuance. `other` requires an explicitly registered handler;
database input is never constantized.

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/catalog/add_ons test/services/orders/fulfillment`

Verified: 10 tests, 79 assertions, 0 failures, and 0 errors with
`N_PLUS_ONE=1`.

The final full suite passes 2,652 tests and 11,009 assertions with zero
failures and zero errors under `N_PLUS_ONE=1`.

- [x] **Step 5: REFACTOR — extract only repeated immutable side-effect evidence**

Keep delivery-specific logic in handlers and use the existing order-item
`fulfillment_status` per the Orders plan. Noncredential add-ons never create
tickets, credentials, QR/PNR values, or a parallel fulfillment table.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/services/catalog/add_ons app/services/orders/fulfillment config/locales/catalog/add_ons.en.yml config/locales/orders/fulfillment.en.yml test/services/catalog/add_ons test/services/orders/fulfillment docs/superpowers/plans/2026-07-17-streaming-addons-links-implementation.md
git commit -m "feat(catalog): fulfill typed add-ons"
```

## Task 5: Issue parking packages and preserve transfer boundaries

**Files:**
- Create: `app/services/parking/issue_package.rb`
- Create: `app/services/parking/fulfill_order_item.rb`
- Create: `config/locales/parking.en.yml`
- Modify: `app/models/catalog/event_product.rb`
- Modify: `app/models/ticketing/ticket.rb`
- Modify: `app/services/ticketing/packages/issue.rb`
- Modify: `app/services/ticketing/credential_generations/create_initial_group.rb`
- Modify: `app/services/ticketing/credential_generations/replace.rb`
- Modify: `app/services/ticketing/attendee_index/upsert.rb`
- Modify: `app/services/ticketing/admissions/consume.rb`
- Modify: `app/services/ticketing/transfers/initiate.rb`
- Modify: `app/services/ticketing/transfers/accept.rb`
- Modify: `app/services/ticketing/outbox_handlers/order_fulfilled.rb`
- Modify: `db/migrate/20260812090009_add_ticketing_package_credential_constraints.rb`
- Modify: `db/structure.sql`
- Test: `test/services/parking/issue_package_test.rb`
- Test: `test/integration/parking/parking_admission_test.rb`
- Test: `test/integration/ticketing/add_on_transfer_boundary_test.rb`

- [x] **Step 1: RED — distinguish included access from separate parking product**

Prove included parking follows ticket transfer; separately purchased parking remains with parking package owner; parking zones/use limits use common scanner admission; ticket delegation does not assign separate parking.

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/parking test/integration/parking test/integration/ticketing/add_on_transfer_boundary_test.rb`

Verified initial RED: 7 tests, 0 assertions, and 7 expected missing-service
errors because the parking boundary did not exist.

- [x] **Step 3: GREEN — reuse package issuance and product-access scanning**

Validate fulfilled paid parking items, then call `Ticketing::Packages::Issue`
for each parking unit. The shared ticket package boundary now accepts the
credential-bearing product types `ticket` and `parking`; ticket-only settings
(registrations, ticket types, transfer/delegation controls, and `qr_and_id`)
remain optional or disabled for parking. Parking uses
`catalog_product_accesses.type = 'parking'`, event date, explicit usage limit,
and zone grants. No parking QR table is created; the common credential,
attendee-index, validator, check-in, and admission-use pipeline is reused.

Separately purchased parking remains a distinct ticket/order-item owner. Only
access rows on the transferred ticket product follow a ticket transfer; order
co-location and delegation never move the separate parking package.

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/services/parking test/integration/parking test/integration/ticketing/add_on_transfer_boundary_test.rb`

Verified: 8 tests, 53 assertions, 0 failures, and 0 errors with `N_PLUS_ONE=1`.

The final full suite passes 2,660 tests and 11,062 assertions with zero
failures and zero errors under `N_PLUS_ONE=1`.

- [x] **Step 5: REFACTOR — remove implicit order bundles**

Only access rows on the same package move together; order co-location never
changes ownership. The existing shared credential schema remains the only
parking credential representation.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/services/parking config/locales/parking.en.yml app/models/catalog/event_product.rb app/models/ticketing/ticket.rb app/services/ticketing/packages/issue.rb app/services/ticketing/credential_generations/create_initial_group.rb app/services/ticketing/credential_generations/replace.rb app/services/ticketing/attendee_index/upsert.rb app/services/ticketing/admissions/consume.rb app/services/ticketing/transfers/initiate.rb app/services/ticketing/transfers/accept.rb app/services/ticketing/outbox_handlers/order_fulfilled.rb db/migrate/20260812090009_add_ticketing_package_credential_constraints.rb db/structure.sql test/services/parking test/integration/parking test/integration/ticketing/add_on_transfer_boundary_test.rb docs/superpowers/plans/2026-07-17-streaming-addons-links-implementation.md
git commit -m "feat(parking): issue parking credentials"
```

## Task 6: Add organizer add-on reporting

**Files:**
- Create: `app/queries/catalog/add_on_sales_report.rb`
- Create: `app/controllers/catalog/event_add_on_reports_controller.rb`
- Create: `app/policies/catalog/add_on_report_policy.rb`
- Create: `app/serializers/catalog/add_on_sales_row_serializer.rb`
- Create: `config/locales/catalog/add_on_sales_report.en.yml`
- Modify: `config/routes.rb`
- Modify: `postman/Digis API_collection.json`
- Test: `test/queries/catalog/add_on_sales_report_test.rb`
- Test: `test/controllers/catalog/event_add_on_reports_controller_test.rb`
- Test support: `test/support/catalog/add_on_report_test_helpers.rb`

- [x] **Step 1: RED — define event/product/currency-safe aggregates and policy**

Test type/name/quantity/gross/refunded/net per settlement currency, event isolation, owner/admin/manager access, staff/scanner denial, and exclusion of answers, consent, stream tokens, QR/PNR, payouts, and notes.

- [x] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/queries/catalog/add_on_sales_report_test.rb test/controllers/catalog/event_add_on_reports_controller_test.rb`

Verified initial RED: 8 tests, 4 assertions, 4 expected route failures, and
4 missing-query errors.

- [x] **Step 3: GREEN — aggregate immutable order/refund facts**

Use one SQL query grouped by product and both currency snapshots; successful
refunds are pre-aggregated before joining so item gross values are not
multiplied by refund rows. Amounts remain in the immutable item charge
currency, while the order-level settlement currency is returned explicitly;
reporting never performs live FX conversion. The controller validates
allowlisted filters, authorizes the event, calls the query, and renders
explicit AMS fields. `/api/v1` stays in routes, not Ruby namespaces.

- [x] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/queries/catalog/add_on_sales_report_test.rb test/controllers/catalog/event_add_on_reports_controller_test.rb`

Verified focused Task 6 suite: 9 tests, 41 assertions, 0 failures, and 0
errors with `N_PLUS_ONE=1`. The broader Catalog authorization/report suite
passes 12 tests and 47 assertions with zero failures and zero errors.

The final full suite passes 2,669 tests and 11,103 assertions with zero
failures and zero errors under `N_PLUS_ONE=1`.

- [x] **Step 5: REFACTOR — enforce bounded query count**

The report maps one SQL result set directly into immutable rows, performs no
association loading while serializing, and adds no speculative indexes. Mixed
charge/settlement currencies remain visible as separate fields rather than
being silently converted.

- [ ] **Step 6: Commit — user-owned**

```bash
git add app/queries/catalog app/controllers/catalog app/policies/catalog app/serializers/catalog config/locales/catalog/add_on_sales_report.en.yml config/routes.rb postman/'Digis API_collection.json' test/queries/catalog test/controllers/catalog test/support/catalog/add_on_report_test_helpers.rb docs/superpowers/plans/2026-07-17-streaming-addons-links-implementation.md
git commit -m "feat(catalog): report add-on sales"
```

## Task 7: Create feature-gated branded links

**Files:**
- Create: `db/migrate/20260717210202_create_links_short_links.rb`
- Create: `db/migrate/20260717210203_create_links_short_link_clicks.rb`
- Create: `app/models/links/short_link.rb`
- Create: `app/models/links/short_link_click.rb`
- Create: `app/services/links/create.rb`
- Create: `app/services/links/resolve.rb`
- Create: `app/services/links/target_resolver.rb`
- Create: `app/jobs/links/record_click_job.rb`
- Create: `app/controllers/links/redirects_controller.rb`
- Create: `app/policies/links/short_link_policy.rb`
- Create: `config/initializers/short_links.rb`
- Create: `config/locales/links.en.yml`
- Modify: `db/structure.sql`
- Modify: `config/routes.rb`
- Modify: `postman/Digis API_collection.json`
- Test: `test/services/links/resolve_test.rb`
- Test: `test/integration/links/redirect_concurrency_test.rb`
- Test: `test/controllers/links/redirects_controller_test.rb`

- [x] **Step 1: RED — specify safe redirects and atomic click cap**

The tests specify internal event resolution, disabled fallback, case-insensitive
slugs, reserved routes, target/custom-URL XOR, HTTPS-only destinations, expiry,
canonical uniqueness, atomic click limits under concurrency, and ticket links
that resolve only to a page path rather than credential material.

- [x] **Step 2: Run RED**

Run: `N_PLUS_ONE=1 bin/rails test test/services/links test/integration/links test/controllers/links/redirects_controller_test.rb`

Initial RED result: 12 tests, 0 assertions, and 12 `NameError` errors because
the `Links` implementation did not yet exist.

- [x] **Step 3: GREEN — allowlist targets and conditionally increment**

Implemented feature-gated branded redirects with:

- a separate migration for each table, UUIDv7 keys, foreign keys, reserved
  route validation, lower-case slug uniqueness, canonical-target uniqueness,
  target/custom-URL XOR, HTTPS checks, and click-bound constraints;
- an allowlisted target resolver that never constantizes database input and
  maps internal resources back through normal application routes;
- a policy-protected `Links::Create` service and a public `Links::Resolve`
  service whose click cap is enforced by one conditional atomic `UPDATE`;
- a host-constrained redirect route, configuration defaulting to disabled, and
  normal-route fallback while the feature is disabled;
- asynchronous, sanitized click-detail recording that cannot make a successful
  redirect fail; and
- locale-backed error messages plus a Postman request and variables for the
  branded host and slug.

- [x] **Step 4: Run GREEN**

Run: `N_PLUS_ONE=1 bin/rails test test/services/links test/integration/links test/controllers/links/redirects_controller_test.rb`

Verified: 12 tests, 43 assertions, 0 failures, and 0 errors with `N_PLUS_ONE=1`.

- [x] **Step 5: REFACTOR — preserve normal-route fallback**

Branded links remain opt-in through `SHORT_LINKS_ENABLED`; the main host keeps
its normal routes, and disabled branded links resolve through their normal
internal target without consuming clicks. Ticket targets remain page paths and
do not expose credential material.

- [ ] **Step 6: Commit — user-owned**

```bash
git add db/migrate/20260717210202_create_links_short_links.rb db/migrate/20260717210203_create_links_short_link_clicks.rb db/structure.sql app/models/links app/services/links app/jobs/links app/controllers/links app/policies/links config/initializers/short_links.rb config/locales/links.en.yml config/routes.rb postman/'Digis API_collection.json' test/services/links test/integration/links test/controllers/links docs/superpowers/plans/2026-07-17-streaming-addons-links-implementation.md
git commit -m "feat(links): add optional branded redirects"
```

## Task 8: Backfill canonical links and retain privacy-limited analytics

This task owns append-only `links_short_link_clicks`; redirects never require a click row to succeed, and click analytics never grant authorization.

**Files:**
- Create: `app/jobs/links/backfill_canonical_links_job.rb`
- Create: `app/jobs/links/purge_expired_clicks_job.rb`
- Test: `test/jobs/links/backfill_canonical_links_job_test.rb`
- Test: `test/jobs/links/purge_expired_clicks_job_test.rb`

- [ ] **Step 1: RED — specify enable-later operation and retention**

Test repeatable events/tickets/organizations backfill, existing canonical preservation, collision retry, disabled no-op, deleting only expired click details, and retaining target/counter.

- [ ] **Step 2: Run RED**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/links`

Expected: FAIL because jobs are missing.

- [ ] **Step 3: GREEN — process bounded Solid Queue batches**

Backfill uses `in_batches`, `Links::Create`, and stable target-derived idempotency; rely on canonical unique index. Purge deletes click-detail rows only beyond platform retention; aggregate `click_count` remains. Use `Rails.configuration.x.short_links.enabled` and configured host without dual-write compatibility branches.

- [ ] **Step 4: Run GREEN**

Run: `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test test/jobs/links`

Expected: PASS.

- [ ] **Step 5: REFACTOR — keep feature rollout configuration-only**

No ticket/event schema or serializer branch is required when the short domain is absent.

- [ ] **Step 6: Commit**

```bash
git add app/jobs/links test/jobs/links
git commit -m "feat(links): backfill canonical links safely"
```

## Acceptance gate

- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails db:test:prepare`.
- [ ] Run streaming model/service/job/controller and lifecycle integration tests.
- [ ] Run catalog add-on, order fulfillment, parking, reporting, and transfer-boundary tests.
- [ ] Run link service/job/controller and concurrency tests.
- [ ] Prove concurrent stream creation cannot exceed device limit and lifecycle changes block immediately.
- [ ] Prove paid `soft_gated` YouTube products disclose link-sharing risk, YouTube cannot satisfy `signed`, and no internal/self-hosted provider is registered.
- [ ] Prove the Digis session token and provider playback grant are separate, bounded values and neither token digest nor provider credentials enter public serializers.
- [ ] Prove included access follows ticket while separate add-ons retain ownership and only credential-bearing products enter QR/PNR.
- [ ] Prove short links neither contain nor bypass credential, audience, visibility, or authentication authority.
- [ ] Prove serializers expose no provider secrets, token digests, answers, consent, or finance/payout data.
- [ ] Run `PATH="$HOME/.asdf/shims:$PATH" bundle exec rails test`.

Accept only when streaming lifecycle integration, parking scanner reuse, add-on ownership, and normal-route fallback all pass.
