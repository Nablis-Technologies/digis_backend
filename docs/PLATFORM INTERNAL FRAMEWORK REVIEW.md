# PLATFORM NAMESPACE: INTERNAL FRAMEWORK REVIEW

**Date**: May 17, 2026
**Lens**: Is this a world-class internal development framework?

---

## WHAT YOU HAVE (ASSESSMENT)

Your Core namespace is **not just extracted code** — it's a coherent set of composable building blocks. Here's the inventory:

| Component | Lines | Purpose | Quality |
|-----------|-------|---------|---------|
| `Common` concern | 161 | CRUD controller scaffolding | A+ |
| `JsonResponse` concern | 89 | Consistent API responses | A |
| `Pagination` concern | 82 | Offset-based pagination with links | A |
| `Filterable` concern | 16 | Safe Ransack wrapper | A |
| `Authenticatable` concern | 75 | JWT token auth | A |
| `TokenAuthenticatable` concern | 12 | Refresh token guard | A |
| `Authorizable` concern | 56 | Pundit with fallback | A+ |
| `AuditableController` concern | 519 | Snapshot-based audit logging | A+ |
| `ReviewableController` concern | 316 | State machine / approval workflow | A |
| `AuditableModel` concern | 47 | Model-side audit recording | A |
| `ReviewableModel` concern | 53 | Model-side review status | A |
| `UserAuthenticatable` concern | 66 | Password/OTP auth mixin | B (needs OTP) |
| `AuthService` | 80 | Auth orchestration | A |
| `TokenService` | 57 | JWT issuance/decoding | A |
| `PermissionRegistry` | 52 | DSL-based permission seeding | A |
| `AuditLoggerJob` | 315 | Async audit processing | A |
| `ApplicationPolicy` | 79 | RBAC policy base | A |
| `ApplicationRecord` | 10 | Secure base model | A |
| `Error` hierarchy | 24 | Custom exceptions | A |
| Serializers (5 files) | ~70 | API serialization | A |
| **Total** | **~1,800** | | |

---

## WHAT MAKES IT A FRAMEWORK (NOT JUST CODE)

A framework is defined by **how it's used**, not what it contains. Your Core namespace already has framework characteristics:

### ✅ Convention Over Configuration
- `Common` provides default CRUD — override with blocks when needed
- `ApplicationRecord` requires explicit `ransackable_attributes` — secure by default
- `ApplicationPolicy` provides fallback — no need to write policies for simple CRUD

### ✅ Composability
- Concerns are independent: use `Common` without `AuditableController`, use `Filterable` without `Pagination`
- No hard dependencies between concerns (they include each other where needed, but not circularly)

### ✅ Extensibility Points
- `Common`: `resolve_block_result` lets controllers inject custom logic into any CRUD action
- `AuditableController`: `auditable_record_for`, `auditable_record_map`, `auditable_record` hooks
- `ReviewableController`: `before_reviewable_action`, `after_reviewable_action` callbacks
- `Authorizable`: `policy_target_for_authorization` hook

### ✅ Developer Experience
- `Common#set_clazz` raises clear error: `"ControllerName must declare self.model_class"`
- `AuditableController` resolution failure prints detailed diagnostic with solution options
- Permission validation warns at definition time, not runtime

---

## DETAILED ANALYSIS OF QUESTIONED COMPONENTS

### 1. Event Bus: Simple Publisher vs Proper Event Bus

**The Question**: Do we need a proper event bus (Wisper, dry-events, Redis Streams) or is a simple in-memory publisher enough?

**The Answer**: Start with **ActiveSupport::Notifications** (built into Rails). Graduate to async job-based events when you need reliability.

#### Why Not a Simple In-Memory Publisher

The simple `Core::Publisher.subscribe/publish` pattern I initially proposed has three fatal flaws for production:

| Problem | Impact | Example |
|---------|--------|---------|
| **Synchronous execution** | Subscribers run in the request thread, slowing response time | SMS sending adds 2s to every ticket purchase |
| **No persistence** | If the process crashes, events are lost forever | Ticket purchased → process dies → no confirmation SMS sent |
| **No retry** | Failed subscribers fail silently | SMS provider timeout → user never gets ticket |

#### Why Not Wisper / dry-events / Kafka (Yet)

| Library | Why Not Now |
|---------|-------------|
| Wisper | Adds a gem dependency for what Rails already provides |
| dry-events | Requires dry-rb ecosystem adoption, overkill for monolith |
| Kafka / Redis Streams | Distributed system complexity. You don't have this problem yet. |

#### The Right Approach: Two-Tier Event System

**Tier 1: ActiveSupport::Notifications** (for synchronous, in-process events)

This is built into Rails. No gem needed. Works like a pub-sub system:

```ruby
# Publishing (in your service or controller):
ActiveSupport::Notifications.instrument("order.created", {
  order_id: order.id,
  user_id: user.id,
  phone: user.phone
})

# Subscribing (in an initializer):
# config/initializers/core_events.rb
ActiveSupport::Notifications.subscribe("order.created") do |name, start, finish, id, payload|
  user = Core::User.find(payload[:user_id])
  order = Order.find(payload[:order_id])
  SmsService.send_ticket_confirmation(phone: user.phone, order: order)
end

ActiveSupport::Notifications.subscribe("order.created") do |name, start, finish, id, payload|
  AnalyticsService.track_purchase(payload[:order_id])
end

ActiveSupport::Notifications.subscribe("ticket.scanned") do |name, start, finish, id, payload|
  RealtimeService.broadcast_entry(payload[:ticket_id], payload[:scanner_id])
end
```

**Benefits**:
- Zero dependencies (Rails built-in)
- Subscribers can be added/removed without touching publishing code
- Payload is a simple hash — no schema enforcement overhead
- Can be tested: `assert_notifications_sent("order.created")` in tests

**Limitations**:
- Still synchronous (subscribers run in the same thread)
- No persistence (lost on crash)
- No automatic retry

**When to use**: Analytics, logging, cache invalidation, non-critical notifications.

---

**Tier 2: Background Job Events** (for async, reliable, retryable events)

For critical events (SMS, email, payment webhooks), publish to a background job:

```ruby
# Publishing:
ActiveSupport::Notifications.instrument("order.created", {
  order_id: order.id,
  user_id: user.id,
  phone: user.phone
})

# Subscriber that enqueues a job:
ActiveSupport::Notifications.subscribe("order.created") do |name, start, finish, id, payload|
  TicketConfirmationJob.perform_later(payload[:order_id], payload[:user_id])
end

# The job handles retries, persistence, and failure:
class TicketConfirmationJob < ApplicationJob
  queue_as :notifications
  retry_on SmsService::DeliveryError, wait: :exponentially_longer, attempts: 5
  discard_on Core::User::NotFoundError

  def perform(order_id, user_id)
    user = Core::User.find(user_id)
    order = Order.find(order_id)
    SmsService.send_ticket_confirmation(phone: user.phone, order: order)
  end
end
```

**Benefits**:
- Async (doesn't block the request)
- Persistent (jobs survive process restarts)
- Retryable (built-in retry with backoff)
- Observable (job queue metrics, failure alerts)

**When to use**: SMS, email, payment processing, webhook delivery, anything that must succeed.

---

**The Architecture**:

```
┌─────────────────────────────────────────────────────────────┐
│                     Order Creation                          │
│                                                             │
│  if order.save                                              │
│    ActiveSupport::Notifications.instrument(                 │
│      "order.created", { order_id: order.id, ... }           │
│    )                                                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
          ▼                ▼                ▼
   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
   │ Analytics   │  │ Cache       │  │ Job         │
   │ (sync)      │  │ Invalidation│  │ Enqueue     │
   │             │  │ (sync)      │  │ (async)     │
   └─────────────┘  └─────────────┘  └──────┬──────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ TicketConfirm   │
                                   │ Job (retries)   │
                                   └─────────────────┘
```

**Recommendation**: Use `ActiveSupport::Notifications` for everything. Let subscribers decide whether to run sync or enqueue a job. This gives you the simplicity of a pub-sub system with the reliability of background jobs where needed.

---

### 2. Query Objects vs Ransack/Filterable: Are They Redundant?

**The Question**: If we have `Filterable` (Ransack wrapper), why do we need query objects? Aren't they doing the same thing?

**The Answer**: They solve **completely different problems**. They're complementary, not redundant.

#### Ransack/Filterable: User-Driven Ad-Hoc Filtering

**Purpose**: Let users filter data by arbitrary combinations of fields.

**How it works**: User sends `?q[name_cont]=music&q[date_gteq]=2026-01-01` → Ransack builds the SQL.

**Characteristics**:
- **Unpredictable**: You don't know what fields users will filter by
- **Combinatorial**: Users can combine any fields in any way
- **UI-driven**: Tied to search forms, admin panels, filter sidebars
- **Declarative**: User says "what" they want, not "how" to find it

**Example use cases**:
- Admin panel: "Show me all events in Addis Ababa between Jan-Mar that are published"
- API: `GET /api/v1/events?q[venue_city_eq]=Addis+Ababa&q[status_eq]=published`
- Search form: User types "comedy" and selects "this weekend"

**Why Ransack is perfect for this**: It handles the combinatorial explosion of filter combinations without you writing code for each one.

---

#### Query Objects: Developer-Driven Business Logic

**Purpose**: Encapsulate specific, reusable business queries that combine multiple conditions, scopes, and possibly external data.

**How it works**: Developer calls `FeaturedEventsQuery.near(user).this_week.call` → returns a curated list.

**Characteristics**:
- **Predictable**: You know exactly what this query does
- **Named**: The class name describes the business intent
- **Composable**: Can chain query objects together
- **Testable**: Unit test the query in isolation

**Example use cases**:
- "Featured events near this user in the next 7 days" (combines location, date, featured flag, sorting)
- "Events the user has purchased but hasn't attended yet" (combines orders, tickets, attendance)
- "Top-selling events this month by revenue" (combines orders, payments, aggregation)
- "Events that match the user's preferences based on past purchases" (recommendation engine)

**Why Query Objects are perfect for this**: These are too complex for Ransack (they involve business logic, not just field filtering) and too important to scatter across controllers.

---

#### Side-by-Side Comparison

| Aspect | Ransack/Filterable | Query Objects |
|--------|-------------------|---------------|
| **Who drives it** | End user (via params) | Developer (via code) |
| **Predictability** | Unpredictable combinations | Fixed, named intent |
| **Complexity** | Simple field comparisons | Complex business logic |
| **External data** | No (DB fields only) | Yes (APIs, geolocation, ML) |
| **Testing** | Hard to test all combinations | Easy to test specific query |
| **Controller code** | `filter_records(Event)` | `EventsQuery.new(filters).call` |
| **Example** | `?q[city_eq]=Addis` | `EventsQuery.near(user).featured.call` |

#### How They Work Together

In a real controller, you'd use **both**:

```ruby
class Api::V1::EventsController < Core::ApplicationController
  include Core::Filterable  # For ad-hoc user filtering

  def index
    # Step 1: Start with a business query (developer-driven)
    base_scope = EventsQuery.new(Event.published, filters: {
      location: current_user&.location,
      date_from: Date.current,
      featured: params[:featured]
    }).call

    # Step 2: Apply user-driven ad-hoc filtering on top (user-driven)
    filtered_scope = filter_records(base_scope)

    # Step 3: Paginate
    render_success(data: apply_pagination(filtered_scope))
  end
end
```

**The flow**:
1. Query object applies business logic (featured, near user, this week)
2. Ransack applies user filters (city, category, price range)
3. Pagination handles the result set

**This is not redundant** — it's layered. Query objects handle the "what should we show" logic. Ransack handles the "how should we narrow it down" logic.

---

### 3. Slugable Concern: What It Does and Why You Need It

**The Question**: What does `Slugable` actually do? What benefit does it give?

**The Answer**: It automatically generates URL-friendly identifiers from any text column, handles uniqueness conflicts, and eliminates manual slug management across every model that needs public URLs.

#### The Problem Without Slugable

Every model that needs a public URL reimplements the same logic:

```ruby
# Event model:
before_validation :generate_slug, on: :create
def generate_slug
  self.slug = title.parameterize
  # ... handle uniqueness ...
end

# Organization model:
before_validation :generate_slug, on: :create
def generate_slug
  self.slug = name.parameterize
  # ... handle uniqueness (different logic!) ...
end

# Venue model:
before_validation :generate_slug, on: :create
def generate_slug
  self.slug = venue_name.parameterize
  # ... handle uniqueness (yet another implementation!) ...
end
```

Three models, three slightly different implementations, three places to bug-fix.

#### What Slugable Does

```ruby
# One concern, used everywhere:
class Event < ApplicationRecord
  include Core::Slugable
  slugable source: :title, target: :slug
end

class Organization < ApplicationRecord
  include Core::Slugable
  slugable source: :name, target: :slug
end

class Venue < ApplicationRecord
  include Core::Slugable
  slugable source: :venue_name, target: :slug, unique: false
end
```

#### Detailed Implementation

```ruby
# app/models/concerns/platform/slugable.rb
# frozen_string_literal: true

module Core
  module Slugable
    extend ActiveSupport::Concern

    class_methods do
      # Declare a slug for this model.
      #
      # @param source [Symbol] The attribute to generate the slug from (e.g. :title, :name)
      # @param target [Symbol] The attribute to store the slug in (default: :slug)
      # @param unique [Boolean] Whether to ensure uniqueness by appending -1, -2, etc.
      #
      # @example
      #   class Event < ApplicationRecord
      #     include Core::Slugable
      #     slugable source: :title, target: :slug
      #   end
      #
      #   event = Event.create!(title: "Addis Music Festival 2026")
      #   event.slug # => "addis-music-festival-2026"
      #
      def slugable(source: :name, target: :slug, unique: true)
        class_attribute :_slug_source, default: source
        class_attribute :_slug_target, default: target
        class_attribute :_slug_unique, default: unique

        before_validation :_generate_slug, on: :create

        # Allow slug regeneration if source changes and slug hasn't been manually set
        before_validation :_regenerate_slug_if_source_changed, on: :update
      end
    end

    # Generate a slug from the source attribute.
    # Handles uniqueness by appending -1, -2, etc. if needed.
    def generate_slug_from_source
      source_value = send(self.class._slug_source)
      return if source_value.blank?

      base_slug = source_value.to_s.parameterize
      return base_slug unless self.class._slug_unique

      _unique_slug(base_slug)
    end

    private

    def _generate_slug
      return if send(self.class._slug_target).present?
      slug = generate_slug_from_source
      send("#{self.class._slug_target}=", slug) if slug.present?
    end

    def _regenerate_slug_if_source_changed
      return unless send(self.class._slug_source).changed?

      # Only regenerate if the slug was auto-generated (matches the old source)
      old_slug = send(self.class._slug_target)
      old_source_slug = _slug_was.parameterize
      return unless old_slug == old_source_slug || old_slug.start_with?("#{old_source_slug}-")

      slug = generate_slug_from_source
      send("#{self.class._slug_target}=", slug) if slug.present?
    end

    def _slug_was
      send(self.class._slug_source).was.to_s
    end

    def _unique_slug(base_slug)
      slug = base_slug
      counter = 1

      # Use a scoped query to avoid N+1 with large tables
      scope = self.class.where(self.class._slug_target => slug)
      scope = scope.where.not(id: id) if persisted?

      while scope.exists?
        slug = "#{base_slug}-#{counter}"
        scope = self.class.where(self.class._slug_target => slug)
        scope = scope.where.not(id: id) if persisted?
        counter += 1

        # Safety valve: prevent infinite loops
        raise "Could not generate unique slug for #{base_slug} after #{counter} attempts" if counter > 100
      end

      slug
    end
  end
end
```

#### Benefits

| Benefit | Without Slugable | With Slugable |
|---------|-----------------|---------------|
| **DRY** | Reimplement per model | One concern, used everywhere |
| **Uniqueness** | Manual loop, easy to bug | Built-in with safety valve |
| **Flexibility** | Hardcoded source/target | Configurable per model |
| **Updates** | Manual regeneration logic | Auto-regenerates if source changes |
| **Testing** | Test each model's slug logic | Test concern once |
| **URLs** | `/events/uuid-12345` | `/events/addis-music-festival-2026` |

#### Real-World Impact for Your Core

**Event URLs**:
```
/events/addis-music-festival-2026        ← SEO-friendly, shareable, readable
/events/550e8400-e29b-41d4-a716-446655440000  ← UUID: ugly, not shareable
```

**Organization URLs**:
```
/orgs/addis-live                         ← Clean, brandable
/orgs/550e8400-e29b-41d4-a716-446655440000  ← UUID: meaningless
```

**SEO**: Search engines prefer readable URLs. Users trust them. They're shareable on social media.

**When to use**: Any model with a public-facing URL. Events, organizations, venues, categories. Not needed for internal-only models (audit logs, memberships, payments).

---

## WHAT'S MISSING FOR WORLD-CLASS

### 1. Configuration Module

**Problem**: No central place to configure framework behavior. Settings are scattered across concerns.

**Solution**: Add `Core.configure`:

```ruby
# lib/platform/configuration.rb
module Core
  class Configuration
    attr_accessor :default_per_page, :max_per_page, :otp_expiry_minutes,
                  :otp_max_attempts, :jwt_secret_key, :sms_provider

    def initialize
      @default_per_page = 25
      @max_per_page = 100
      @otp_expiry_minutes = 5
      @otp_max_attempts = 3
      @jwt_secret_key = nil
      @sms_provider = :telebirr
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end
  end
end

# config/initializers/platform.rb
Core.configure do |config|
  config.default_per_page = 25
  config.otp_expiry_minutes = 5
  config.sms_provider = :telebirr
end
```

Then concerns read from `Core.configuration` instead of hardcoding values.

---

### 2. Base Service Object

**Problem**: Services (`AuthService`, `TokenService`, `OtpService`) have inconsistent interfaces.

**Solution**: Add a callable service base with Result objects:

```ruby
# app/services/platform/base_service.rb
module Core
  class BaseService
    class Result
      attr_reader :value, :error, :success

      def self.success(value = nil) = new(success: true, value: value)
      def self.failure(error) = new(success: false, error: error)

      def initialize(success: true, value: nil, error: nil)
        @success = success
        @value = value
        @error = error
      end

      def failure? = !success
    end

    def self.call(...) = new(...).call

    def call
      raise NotImplementedError, "#{self.class.name} must implement #call"
    end
  end
end
```

---

### 3. Query Objects

**Purpose**: Encapsulate business logic queries (complementary to Ransack, not redundant — see detailed analysis above).

```ruby
# app/queries/platform/base_query.rb
module Core
  class BaseQuery
    def initialize(scope = nil)
      @scope = scope || default_scope
    end

    def call
      @scope
    end

    private

    def default_scope
      raise NotImplementedError
    end
  end
end
```

---

### 4. Event System (ActiveSupport::Notifications)

**Purpose**: Decouple side effects from core logic (see detailed analysis above).

```ruby
# Publishing:
ActiveSupport::Notifications.instrument("order.created", { order_id: order.id, user_id: user.id })

# Subscribing (config/initializers/core_events.rb):
ActiveSupport::Notifications.subscribe("order.created") do |name, start, finish, id, payload|
  TicketConfirmationJob.perform_later(payload[:order_id], payload[:user_id])
end
```

---

### 5. Soft Delete Concern

```ruby
# app/models/concerns/platform/soft_deletable.rb
module Core
  module SoftDeletable
    extend ActiveSupport::Concern

    included do
      default_scope { where(deleted_at: nil) }
      scope :with_deleted, -> { unscope(where: :deleted_at) }
      scope :only_deleted, -> { with_deleted.where.not(deleted_at: nil) }
    end

    def soft_delete
      update(deleted_at: Time.current)
    end

    def restore
      update(deleted_at: nil)
    end

    def deleted?
      deleted_at.present?
    end
  end
end
```

---

### 6. Slugable Concern

See detailed analysis above.

---

### 7. Rate Limiting

```ruby
# app/services/platform/rate_limiter.rb
module Core
  class RateLimiter
    def initialize(key:, max_requests:, period:)
      @key = "rate_limit:#{key}"
      @max_requests = max_requests
      @period = period
    end

    def allowed?
      count = Redis.current.get(@key).to_i
      return false if count >= @max_requests

      Redis.current.multi do |pipeline|
        pipeline.incr(@key)
        pipeline.expire(@key, @period) if count == 0
      end
      true
    end
  end
end
```

---

### 8. Request ID Tracking

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :request_id, :user_agent, :ip_address, :user
end
```

---

### 9. Generator Improvements

Add: `rails generate platform:service`, `:query`, `:policy`, `:concern`

---

### 10. Health Check Endpoint

```ruby
# app/controllers/platform/health_controller.rb
class Core::HealthController < Core::ApplicationController
  skip_before_action :authenticate_user, :authorize_action!

  def show
    checks = { database: database_check, redis: redis_check }
    status = checks.all? { |_, r| r[:status] == "ok" } ? :ok : :service_unavailable
    render json: { status: status, checks: checks }, status: status
  end
end
```

---

## FRAMEWORK ARCHITECTURE: RECOMMENDED STRUCTURE

```
app/
  controllers/
    concerns/
      platform/
        authenticatable.rb
        authorizable.rb
        auditable_controller.rb
        common.rb
        filterable.rb
        json_response.rb
        pagination.rb
        request_trackable.rb        # NEW
        reviewable_controller.rb
        rate_limitable.rb           # NEW
  models/
    concerns/
      platform/
        auditable_model.rb
        reviewable_model.rb
        soft_deletable.rb           # NEW
        slugable.rb                 # NEW
        user_authenticatable.rb
    platform/
      application_record.rb
      user.rb
      current.rb                    # NEW
  services/
    platform/
      base_service.rb               # NEW
      rate_limiter.rb               # NEW
      auth_service.rb
      token_service.rb
      otp_service.rb
  queries/
    platform/
      base_query.rb                 # NEW
  jobs/
    platform/
      audit_logger_job.rb
  policies/
    platform/
      application_policy.rb
  errors/
    platform/
      error.rb
      authentication_error.rb
      auditable_record_not_found_error.rb
  serializers/
    platform/
      ...
lib/
  platform/
    configuration.rb                # NEW
    permission_registry.rb
    generators/
      platform/
        service_generator.rb        # NEW
        query_generator.rb          # NEW
        policy_generator.rb         # NEW
config/
  initializers/
    platform.rb                     # NEW (configuration)
    core_events.rb              # NEW (event subscriptions)
```

---

## PRIORITY ROADMAP

### Phase 1: Foundation (Week 1)
1. **Configuration module** — centralize all hardcoded values
2. **Base service object** — consistent service interface
3. **Request ID tracking** — `Current.attributes` for context propagation

### Phase 2: Developer Experience (Week 2)
4. **Query objects** — composable, testable queries (complements Ransack)
5. **Event system** — `ActiveSupport::Notifications` + job-based async
6. **Generator improvements** — service, query, policy generators

### Phase 3: Production Readiness (Week 3)
7. **Rate limiting** — Redis-backed, per-endpoint
8. **Soft delete concern** — safe deletion pattern
9. **Slug concern** — reusable URL generation
10. **Health check endpoint** — monitoring

### Phase 4: Polish (Week 4)
11. **API versioning strategy** — namespace-based
12. **`# frozen_string_literal: true`** — add to all files
13. **Inline documentation** — YARD comments on all public methods
14. **Test suite** — unit tests for every concern and service

---

## WHAT MAKES IT WORLD-CLASS

| Characteristic | Current State | Target State |
|----------------|--------------|--------------|
| Convention over configuration | ✅ Good | ✅ Excellent (with Configuration module) |
| Composability | ✅ Good | ✅ Excellent (concerns are independent) |
| Extensibility | ✅ Good | ✅ Excellent (hooks, callbacks, blocks) |
| Developer experience | ⚠️ Partial | ✅ Excellent (generators, clear errors, docs) |
| Testability | ⚠️ Partial | ✅ Excellent (base service, query objects) |
| Performance | ✅ Good | ✅ Excellent (rate limiting, caching) |
| Security | ✅ Good | ✅ Excellent (rate limiting, request tracking) |
| Documentation | ❌ Missing | ✅ Excellent (YARD, examples, README) |
| Monitoring | ❌ Missing | ✅ Excellent (health checks, request IDs) |
| Consistency | ⚠️ Partial | ✅ Excellent (base service, result objects) |

---

## SUMMARY

**Your Core namespace is already 80% of a world-class internal framework.** The core concerns (Common, Auth, Audit, Review, Authorize) are excellent — well-designed, composable, and production-tested.

**The three components you asked about:**

1. **Event Bus**: Use `ActiveSupport::Notifications` (built into Rails). Subscribe with sync handlers for analytics/cache, and job-enqueueing handlers for SMS/email. No external gem needed.

2. **Query Objects vs Ransack**: Not redundant. Ransack handles user-driven ad-hoc filtering (search forms, admin panels). Query objects handle developer-driven business logic (featured events near user, recommendation engine). Use both — layered.

3. **Slugable**: Auto-generates URL-friendly identifiers from any text column. Eliminates manual slug management across models. Gives you SEO-friendly URLs (`/events/addis-music-festival-2026` vs `/events/uuid-123`).

**The 20% gap is infrastructure**: configuration, base service objects, query objects, events, rate limiting, generators, and documentation. Build Phase 1-2 first for the biggest developer experience boost.
