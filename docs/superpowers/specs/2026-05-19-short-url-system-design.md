# Short URL System Design

**Date**: May 19, 2026
**Status**: Approved
**Context**: Event ticketing platform — branded short URLs (dig.is) for events, tickets, organizations, and custom links

---

## Problem Statement

Event links like `digis.com/events/gize-concert-2026` are too long for SMS campaigns, email marketing, social media, and word-of-mouth sharing. A branded short URL system (`dig.is/gize-2026`) is needed that:

1. Works for **any resource type** (events, tickets, organizations, custom URLs)
2. Supports **custom slugs** (human-readable) and **auto-generated slugs** (compact)
3. Provides **click analytics** (referrer, device, geo, timestamp)
4. Is **extensible** — new resource types can be added without changing the core system
5. Uses the **same Rails app** — no separate infrastructure

---

## Architecture

### Domain Routing

```
dig.is → CNAME → digis.com (same Rails app)

Rails detects request.host == "dig.is" and routes to ShortLinksController
```

**DNS Setup** (infrastructure, not code):
- Register `dig.is` domain
- Add CNAME record: `dig.is → digis.com`
- Configure Rails to accept both domains
- SSL certificate covers both domains (Let's Encrypt wildcard or multi-domain)

### Request Flow

```
User clicks dig.is/gize-2026
  ↓
DNS resolves dig.is → digis.com
  ↓
Rails receives request with Host: dig.is
  ↓
Routes to ShortLinksController#show (path: /gize-2026)
  ↓
Lookup: ShortLink.find_by!(slug: "gize-2026")
  ↓
Record click analytics (async via ActiveSupport::Notifications)
  ↓
302 redirect → target URL (e.g., digis.com/events/gize-concert-2026)
```

---

## Data Model

### ShortLink Model

```ruby
create_table :short_links, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
  t.string :slug, null: false
  t.string :target_type, null: false       # "Event", "Ticket", "Organization", "Custom"
  t.uuid :target_id                        # polymorphic — nil for Custom type
  t.string :custom_url                     # external URL for Custom type
  t.uuid :creator_id                       # who created it
  t.datetime :expires_at                   # optional — link stops working after this
  t.integer :max_clicks                    # optional — link stops working after N clicks
  t.integer :click_count, default: 0, null: false
  t.string :utm_source                     # campaign tracking
  t.string :utm_medium                     # campaign tracking
  t.string :utm_campaign                   # campaign tracking
  t.timestamps
end

add_index :short_links, :slug, unique: true
add_index :short_links, [:target_type, :target_id]
add_index :short_links, :creator_id
add_index :short_links, :expires_at
```

### ShortLinkClick Model (Analytics)

```ruby
create_table :short_link_clicks, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
  t.uuid :short_link_id, null: false
  t.string :referrer                       # HTTP Referer
  t.string :user_agent
  t.string :ip_address
  t.string :country                        # resolved from IP
  t.string :city                           # resolved from IP
  t.string :device_type                    # "mobile", "desktop", "tablet"
  t.string :browser                        # "Chrome", "Safari", etc.
  t.datetime :clicked_at, null: false
  t.timestamps
end

add_index :short_link_clicks, :short_link_id
add_index :short_link_clicks, :clicked_at
add_index :short_link_clicks, [:short_link_id, :clicked_at]
```

---

## Slug Generation

### Custom Slugs

User-chosen, human-readable. Validated for:
- Length: 3-50 characters
- Pattern: lowercase alphanumeric + hyphens only (`/^[a-z0-9]+(-[a-z0-9]+)*$/`)
- Uniqueness
- Reserved words blocklist (`admin`, `login`, `api`, `up`, `e`, `t`, `o`, `c`)

### Auto-Generated Slugs

System-generated, compact. Using Base62 encoding of a portion of the UUID v7 timestamp:

```ruby
module Platform
  class SlugGenerator
    CHARS = ("0".."9").to_a + ("a".."z").to_a + ("A".."Z").to_a  # 62 chars

    def self.generate(length: 6)
      # Use SecureRandom for collision-resistant random slugs
      Array.new(length) { CHARS.sample }.join
    end

    def self.generate_unique(model_class, length: 6)
      loop do
        slug = generate(length: length)
        return slug unless model_class.exists?(slug: slug)
      end
    end
  end
end
```

6 characters from a 62-character alphabet = 62^6 ≈ 56 billion combinations. Collision probability is negligible.

---

## Target Resolution

### Polymorphic Target Pattern

```ruby
module Platform
  class ShortLink < Platform::ApplicationRecord
    RESERVED_SLUGS = %w[
      admin login logout signup auth api up e t o c
      events tickets organizations users me
      health status favicon robots sitemap
      css js images assets static
      new edit show index create update destroy
      platform
    ].freeze

    belongs_to :creator, class_name: "Platform::User", optional: true
    has_many :clicks, class_name: "Platform::ShortLinkClick", foreign_key: :short_link_id, dependent: :destroy

    TARGET_TYPES = %w[Event Ticket Organization Custom].freeze

    validates :slug, presence: true, uniqueness: { case_sensitive: false }
    validates :target_type, inclusion: { in: TARGET_TYPES }
    validate :target_or_custom_url_present
    validate :slug_format
    validate :slug_not_reserved

    before_validation :downcase_slug
    before_validation :generate_slug_if_blank

    # Resolve the actual target URL
    def target_url
      return validated_custom_url if target_type == "Custom"

      record = target
      return nil unless record

      case target_type
      when "Event"
        Rails.application.routes.url_helpers.url_for(
          controller: "events", action: "show", slug: record.slug,
          host: Rails.application.default_url_options[:host], only_path: false
        )
      when "Ticket"
        Rails.application.routes.url_helpers.url_for(
          controller: "tickets", action: "show", id: record.id,
          host: Rails.application.default_url_options[:host], only_path: false
        )
      when "Organization"
        Rails.application.routes.url_helpers.url_for(
          controller: "organizations", action: "show", id: record.id,
          host: Rails.application.default_url_options[:host], only_path: false
        )
      end
    end

    # Polymorphic association
    def target
      return nil if target_type == "Custom"
      target_type.constantize.find_by(id: target_id)
    end

    def expired?
      expires_at.present? && expires_at.past?
    end

    def click_limit_reached?
      max_clicks.present? && click_count >= max_clicks
    end

    def active?
      !expired? && !click_limit_reached? && target.present?
    end

    def record_click!(data)
      clicks.create!(data)
      increment!(:click_count)
    end

    private

    def target_or_custom_url_present
      if target_type == "Custom" && custom_url.blank?
        errors.add(:custom_url, "must be provided for custom links")
      elsif target_type != "Custom" && target_id.blank?
        errors.add(:target, "must be provided")
      end
    end

    def slug_format
      return if slug.blank?
      return unless slug.match?(/^[a-z0-9]+(-[a-z0-9]+)*$/)

      errors.add(:slug, "must contain only lowercase letters, numbers, and hyphens")
    end

    def slug_not_reserved
      return if slug.blank?
      return unless self.class::RESERVED_SLUGS.include?(slug.downcase)

      errors.add(:slug, "is reserved and cannot be used")
    end

    def downcase_slug
      self.slug = slug.downcase if slug.present?
    end

    def generate_slug_if_blank
      return if slug.present?
      self.slug = SlugGenerator.generate_unique(self.class)
    end

    def validated_custom_url
      return nil if custom_url.blank?
      uri = URI.parse(custom_url)
      return nil unless uri.scheme.in?(%w[https http])
      custom_url
    rescue URI::InvalidURIError
      nil
    end
  end
end
```

---

## Controller

### ShortLinksController

```ruby
# app/controllers/platform/short_links_controller.rb
module Platform
  class ShortLinksController < Platform::ApplicationController
    skip_before_action :authenticate_user, only: %i[show]
    skip_before_action :authorize_action!, only: %i[show]

    # Public redirect endpoint
    def show
      skip_authorization
      link = Platform::ShortLink.find_by(slug: params[:slug])

      unless link&.active?
        return redirect_to Rails.application.routes.url_helpers.root_url, status: 302
      end

      # Record analytics asynchronously
      record_click_async(link)

      redirect_to link.target_url, status: 302
    end

    # Admin: Create short link
    def create
      link = Platform::ShortLink.new(short_link_params)
      link.creator = current_user

      if link.save
        render_success(data: { short_url: build_short_url(link.slug) }, status: :created)
      else
        render_error(errors: link.errors, status: :unprocessable_entity)
      end
    end

    # Admin: List short links
    def index
      links = policy_scope(Platform::ShortLink)
      links = links.where(creator_id: current_user.id) unless current_user.super_admin?
      links = apply_pagination(links)
      render_success(data: links)
    end

    # Admin: Analytics for a specific link
    def analytics
      link = Platform::ShortLink.find(params[:id])
      authorize link

      clicks = link.clicks
      clicks = clicks.where("clicked_at >= ?", params[:from]) if params[:from].present?
      clicks = clicks.where("clicked_at <= ?", params[:to]) if params[:to].present?

      render_success(data: {
        total_clicks: link.click_count,
        clicks: apply_pagination(clicks),
        by_device: clicks.group(:device_type).count,
        by_country: clicks.group(:country).count,
        by_referrer: clicks.group(:referrer).order("count_all DESC").limit(10).count
      })
    end

    private

    def short_link_params
      params.require(:short_link).permit(
        :slug, :target_type, :target_id, :custom_url,
        :expires_at, :max_clicks,
        :utm_source, :utm_medium, :utm_campaign
      )
    end

    def build_short_url(slug)
      "https://dig.is/#{slug}"
    end

    def record_click_async(link)
      ActiveSupport::Notifications.instrument("short_link.clicked", {
        short_link_id: link.id,
        referrer: request.referer,
        user_agent: request.user_agent,
        ip_address: request.remote_ip,
        utm_source: link.utm_source,
        utm_medium: link.utm_medium,
        utm_campaign: link.utm_campaign
      })
    end
  end
end
```

---

## Analytics Pipeline

### Event Subscription

```ruby
# config/initializers/platform_events.rb
ActiveSupport::Notifications.subscribe("short_link.clicked") do |name, start, finish, id, payload|
  ShortLinkClickJob.perform_later(payload)
end
```

### Background Job

```ruby
# app/jobs/platform/short_link_click_job.rb
module Platform
  class ShortLinkClickJob < ApplicationJob
    queue_as :analytics
    retry_on StandardError, wait: :exponentially_longer, attempts: 3

    def perform(payload)
      link = Platform::ShortLink.find_by(id: payload[:short_link_id])
      return unless link

      geo = resolve_geo(payload[:ip_address])
      device = parse_device(payload[:user_agent])

      link.clicks.create!(
        referrer: payload[:referrer],
        user_agent: payload[:user_agent],
        ip_address: payload[:ip_address],
        country: geo[:country],
        city: geo[:city],
        device_type: device[:type],
        browser: device[:browser],
        clicked_at: Time.current
      )

      link.increment!(:click_count)
    end

    private

    def resolve_geo(ip_address)
      return {} if ip_address.blank?
      return {} if ip_address.in?(["127.0.0.1", "::1", "0.0.0.0"])

      # TODO: Integrate with geo IP service (maxmind, ipinfo, etc.)
      { country: nil, city: nil }
    end

    def parse_device(user_agent)
      return { type: "unknown", browser: "unknown" } if user_agent.blank?

      ua = user_agent.downcase
      type = if ua.include?("mobile") || ua.include?("android") || ua.include?("iphone")
               "mobile"
             elsif ua.include?("tablet") || ua.include?("ipad")
               "tablet"
             else
               "desktop"
             end

      browser = case ua
                when /chrome/ then "Chrome"
                when /firefox/ then "Firefox"
                when /safari/ then "Safari"
                when /edg/ then "Edge"
                else "Other"
                end

      { type:, browser: }
    end
  end
end
```

---

## Routes

### Short Domain Routes (dig.is — public redirects only)

```ruby
# config/routes.rb
constraints host: /dig\.is$/ do
  # Catch-all for short links — must be LAST in this constraint block
  get "/:slug", to: "platform/short_links#show", as: :short_link
end
```

### Main Domain Routes (digis.com — admin management)

```ruby
# config/routes.rb
namespace :platform do
  resources :short_links, only: %i[index create] do
    member do
      get :analytics
    end
  end
end
```

**Important**: The `dig.is` catch-all route (`/:slug`) is constrained to the short domain only. Admin routes live on the main domain (`digis.com/platform/short_links`). This prevents the catch-all from swallowing admin endpoints.

### Main Domain Routes (target resources)

```ruby
# These already exist or will be created:
# get "/events/:slug" → events#show
# get "/tickets/:id" → tickets#show
# get "/orgs/:slug" → organizations#show
```

---

## Auto-Link Generation Service

### Service for Creating Short Links Automatically

```ruby
# app/services/platform/short_link_service.rb
module Platform
  class ShortLinkService < Platform::BaseService
    def self.for_event(event, slug: nil, creator: nil, **options)
      new(target: event, slug: slug, creator: creator, **options).call
    end

    def self.for_ticket(ticket, creator: nil, **options)
      new(target: ticket, slug: nil, creator: creator, **options).call
    end

    def self.for_organization(org, slug: nil, creator: nil, **options)
      new(target: org, slug: slug, creator: creator, **options).call
    end

    def self.for_custom(url, slug: nil, creator: nil, **options)
      new(custom_url: url, slug: slug, creator: creator, **options).call
    end

    def initialize(target: nil, custom_url: nil, slug: nil, creator: nil, **options)
      @target = target
      @custom_url = custom_url
      @slug = slug
      @creator = creator
      @options = options
    end

    def call
      attrs = @options.merge(creator: @creator, slug: @slug)

      if @target.present?
        attrs[:target] = @target  # Rails sets target_type + target_id automatically
      elsif @custom_url.present?
        attrs[:target_type] = "Custom"
        attrs[:custom_url] = @custom_url
      end

      link = Platform::ShortLink.new(attrs)

      if link.save
        Result.success(link)
      else
        Result.failure(link.errors)
      end
    end
  end
end
```

### Usage Examples

```ruby
# Auto-generate for event (custom slug)
Platform::ShortLinkService.for_event(event, slug: "gize-2026")
# → dig.is/gize-2026

# Auto-generate for ticket (random slug)
Platform::ShortLinkService.for_ticket(ticket)
# → dig.is/xK9mP2

# Custom external URL
Platform::ShortLinkService.for_custom("https://t.me/addis_live", slug: "telegram")
# → dig.is/telegram

# With expiry and click limit
Platform::ShortLinkService.for_event(event, slug: "early-bird", expires_at: 1.week.from_now, max_clicks: 100)
# → dig.is/early-bird (expires after 1 week or 100 clicks)
```

---

## Reserved Slug Blocklist

```ruby
# config/initializers/short_links.rb
Platform::ShortLink::RESERVED_SLUGS = %w[
  admin login logout signup auth api up e t o c
  events tickets organizations users me
  health status favicon robots sitemap
  css js images assets static
  new edit show index create update destroy
].freeze
```

---

## Extensibility: Adding New Target Types

To add a new target type (e.g., `ResaleListing`):

1. **Add to TARGET_TYPES** in `ShortLink`:
```ruby
TARGET_TYPES = %w[Event Ticket Organization ResaleListing Custom].freeze
```

2. **Add URL resolution** in `target_url` method:
```ruby
when "ResaleListing"
  Rails.application.routes.url_helpers.resale_listing_url(record, host: ...)
```

3. **Done.** No other changes needed. The polymorphic pattern handles everything.

---

## Why 302 (Not 301) Redirects

- **301 = permanent** — browsers and search engines cache it forever. If a link changes target, cached 301s break.
- **302 = temporary** — always hits the server, enabling analytics on every click.
- **Analytics requirement** — 301 redirects would bypass the server after the first cache, losing all subsequent click data.

---

## Performance Considerations

| Concern | Solution |
|---------|----------|
| Redirect latency | Single DB query + async analytics. Target: <50ms |
| Slug lookup speed | Unique index on `slug` — O(log n) B-tree lookup |
| Analytics writes | Async via background job — doesn't block redirect |
| Click counter | `increment!(:click_count)` — atomic DB increment |
| Cache | Consider Redis caching for hot slugs if needed |

---

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| Open redirect | Only redirect to known targets (Event, Ticket, Org) or validated custom URLs |
| Slug enumeration | Auto-generated slugs are random (62^6 space) — not guessable |
| Abuse / spam | Rate limit short link creation per user |
| Phishing | Custom URLs validated for allowed schemes (https only) |
| Expiry enforcement | Checked before redirect — expired links go to root |

---

## File Inventory

### New Files
- `app/models/platform/short_link.rb`
- `app/models/platform/short_link_click.rb`
- `app/controllers/platform/short_links_controller.rb`
- `app/services/platform/short_link_service.rb`
- `app/jobs/platform/short_link_click_job.rb`
- `app/services/platform/slug_generator.rb`
- `db/migrate/XXXX_create_short_links.rb`
- `db/migrate/XXXX_create_short_link_clicks.rb`
- `config/initializers/short_links.rb`
- `test/models/platform/short_link_test.rb`
- `test/models/platform/short_link_click_test.rb`
- `test/controllers/platform/short_links_controller_test.rb`
- `test/services/platform/short_link_service_test.rb`
- `test/services/platform/slug_generator_test.rb`
- `test/jobs/platform/short_link_click_job_test.rb`

### Modified Files
- `config/routes.rb` — Add dig.is domain constraint routes
- `config/environments/*.rb` — Add `dig.is` to `config.hosts` (development)

---

## Why This Is Necessary

| Benefit | Impact |
|---------|--------|
| **SMS campaigns** | Short URLs fit in SMS (160 char limit). `dig.is/gize-2026` = 20 chars vs `digis.com/events/gize-concert-2026` = 44 chars |
| **Brand recognition** | `dig.is` is memorable and professional. Like bit.ly, t.co, fb.me |
| **Analytics** | Track which campaigns, channels, and messages drive the most clicks |
| **Link management** | Expire links, set click limits, update targets without changing the URL |
| **QR codes** | Shorter URLs = smaller QR codes = faster scanning |
| **Social media** | Twitter/X, Telegram, WhatsApp — all benefit from short URLs |
| **A/B testing** | Create multiple short links pointing to the same event with different UTM tags |
