# Short URL System — Cloudflare Workers (Option B)

**Date**: May 19, 2026
**Status**: Draft
**Context**: Event ticketing platform — branded short URLs (dig.is) via Cloudflare Workers edge network

---

## Architecture Overview

```
dig.is → Cloudflare DNS → Cloudflare Worker (edge) → 302 redirect → digis.com

digis.com (Rails) → Cloudflare KV API → syncs short links to edge
digis.com (Rails) ← webhook ← Cloudflare Worker sends click analytics
```

### Why Cloudflare Workers

| Metric | Value |
|--------|-------|
| **Redirect latency** | 3-5ms globally (runs at edge, near user) |
| **Free tier** | 100K requests/day (~3M/month) |
| **Paid tier** | $5/month for 10M requests |
| **Locations** | 300+ edge locations worldwide |
| **Uptime** | Cloudflare's 99.99% SLA |
| **Server management** | Zero — no Puma, no Redis, no containers |

### Key Benefits Over Option A (Same Rails App)

1. **Isolation** — Short links work even if Rails app is down
2. **Speed** — 3-5ms vs 50-100ms (no Rails boot, no DB query)
3. **Global** — Users everywhere get fast redirects (edge network)
4. **Cost** — Free tier covers most use cases; cheaper than scaling Rails
5. **Security** — Redirect app has zero access to your database or secrets

---

## System Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         digis.com (Rails)                       │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐ │
│  │ ShortLink    │───→│ SyncService  │───→│ Cloudflare KV API │ │
│  │ Model        │    │ (on create/  │    │ PUT /:slug        │ │
│  │              │    │  update)     │    │                   │ │
│  └──────────────┘    └──────────────┘    └───────────────────┘ │
│                                                                 │
│  ┌──────────────┐    ┌──────────────────┐                       │
│  │ Analytics    │←───│ WebhookReceiver  │←── Cloudflare Worker  │
│  │ Controller   │    │ /webhooks/clicks │    POST               │
│  └──────────────┘    └──────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    Cloudflare Edge (dig.is)                     │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐ │
│  │ Worker       │───→│ Cloudflare   │───→│ 302 Redirect      │ │
│  │ (redirect)   │    │ KV Store     │    │ to target URL     │ │
│  │              │    │ (slug→URL)   │    │                   │ │
│  └──────────────┘    └──────────────┘    └───────────────────┘ │
│        │                                                        │
│        │ POST analytics webhook                                 │
│        ↓                                                        │
│  ┌──────────────┐                                               │
│  │ digis.com    │                                               │
│  │ /webhooks/   │                                               │
│  │ clicks       │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Cloudflare Worker Code

### worker.js

```javascript
// wrangler.toml
// name = "digis-short-links"
// compatibility_date = "2025-01-01"
//
// [[kv_namespaces]]
// binding = "SHORT_LINKS"
// id = "your-kv-namespace-id"
//
// [vars]
// ANALYTICS_WEBHOOK_URL = "https://digis.com/webhooks/clicks"
// ANALYTICS_WEBHOOK_SECRET = "your-shared-secret"

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const slug = url.pathname.slice(1);

    if (!slug || slug.includes('/')) {
      return Response.redirect('https://digis.com/', 302);
    }

    // Lookup slug in KV
    const data = await env.SHORT_LINKS.get(slug, { type: 'json' });

    if (!data || !data.active) {
      return Response.redirect('https://digis.com/', 302);
    }

    // Check expiry
    if (data.expires_at && new Date(data.expires_at) < new Date()) {
      return Response.redirect('https://digis.com/', 302);
    }

    // Check click limit
    if (data.max_clicks && data.click_count >= data.max_clicks) {
      return Response.redirect('https://digis.com/', 302);
    }

    // Send analytics asynchronously (don't wait for it)
    ctx.waitUntil(sendAnalytics(slug, data, request, env));

    // Increment click count in KV (fire and forget)
    ctx.waitUntil(incrementClick(slug, env));

    // Redirect
    return Response.redirect(data.target_url, 302);
  }
};

async function sendAnalytics(slug, data, request, env) {
  const webhookUrl = env.ANALYTICS_WEBHOOK_URL;
  if (!webhookUrl) return;

  const payload = {
    slug,
    referrer: request.headers.get('Referer') || '',
    user_agent: request.headers.get('User-Agent') || '',
    ip_address: request.headers.get('CF-Connecting-IP') || '',
    country: request.headers.get('CF-IPCountry') || '',
    city: request.headers.get('CF-IPCity') || '',
    colo: request.headers.get('CF-Ray')?.split('-')[1] || '',
    timestamp: new Date().toISOString(),
    utm_source: data.utm_source || '',
    utm_medium: data.utm_medium || '',
    utm_campaign: data.utm_campaign || ''
  };

  // Sign the webhook payload
  const secret = env.ANALYTICS_WEBHOOK_SECRET;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(JSON.stringify(payload)));
  const sigHex = Array.from(new Uint8Array(signature)).map(b => b.toString(16).padStart(2, '0')).join('');

  try {
    await fetch(webhookUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Webhook-Signature': `sha256=${sigHex}`
      },
      body: JSON.stringify(payload)
    });
  } catch (e) {
    // Analytics failure should never break the redirect
    console.error('Analytics webhook failed:', e);
  }
}

async function incrementClick(slug, env) {
  try {
    const data = await env.SHORT_LINKS.get(slug, { type: 'json' });
    if (data) {
      data.click_count = (data.click_count || 0) + 1;
      await env.SHORT_LINKS.put(slug, JSON.stringify(data));
    }
  } catch (e) {
    console.error('Failed to increment click count:', e);
  }
}
```

---

## Rails Integration

### Data Model (Same as Option A)

```ruby
# db/migrate/XXXX_create_short_links.rb
create_table :short_links, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
  t.string :slug, null: false
  t.string :target_type, null: false       # "Event", "Ticket", "Organization", "Custom"
  t.uuid :target_id                        # polymorphic
  t.string :custom_url                     # external URL for Custom type
  t.uuid :creator_id
  t.datetime :expires_at
  t.integer :max_clicks
  t.integer :click_count, default: 0, null: false
  t.string :utm_source
  t.string :utm_medium
  t.string :utm_campaign
  t.string :cloudflare_kv_id               # tracks sync status
  t.datetime :last_synced_at
  t.timestamps
end

add_index :short_links, :slug, unique: true
add_index :short_links, [:target_type, :target_id]
add_index :short_links, :creator_id
add_index :short_links, :last_synced_at
```

```ruby
# db/migrate/XXXX_create_short_link_clicks.rb (same as Option A)
create_table :short_link_clicks, id: :uuid, default: -> { "gen_random_uuid_v7()" } do |t|
  t.uuid :short_link_id, null: false
  t.string :referrer
  t.string :user_agent
  t.string :ip_address
  t.string :country
  t.string :city
  t.string :colo                           # Cloudflare data center
  t.datetime :clicked_at, null: false
  t.timestamps
end

add_index :short_link_clicks, :short_link_id
add_index :short_link_clicks, :clicked_at
```

### Cloudflare KV Sync Service

```ruby
# app/services/platform/cloudflare/sync_service.rb
module Platform
  module Cloudflare
    class SyncService
      def initialize
        @api_token = Rails.application.credentials.dig(:cloudflare, :api_token)
        @account_id = Rails.application.credentials.dig(:cloudflare, :account_id)
        @namespace_id = Rails.application.credentials.dig(:cloudflare, :kv_namespace_id)
      end

      def sync_link(short_link)
        payload = {
          target_url: short_link.target_url,
          target_type: short_link.target_type,
          target_id: short_link.target_id,
          active: short_link.active?,
          expires_at: short_link.expires_at&.iso8601,
          max_clicks: short_link.max_clicks,
          click_count: short_link.click_count,
          utm_source: short_link.utm_source,
          utm_medium: short_link.utm_medium,
          utm_campaign: short_link.utm_campaign,
          synced_at: Time.current.iso8601
        }

        response = HTTParty.put(
          "#{base_url}/values/#{short_link.slug}",
          body: payload.to_json,
          headers: auth_headers
        )

        if response.success?
          short_link.update!(last_synced_at: Time.current)
          Result.success(short_link)
        else
          Result.failure("Cloudflare sync failed: #{response.code} - #{response.body}")
        end
      end

      def delete_link(slug)
        response = HTTParty.delete(
          "#{base_url}/values/#{slug}",
          headers: auth_headers
        )

        response.success?
      end

      def bulk_sync(short_links)
        # Cloudflare KV supports bulk writes (up to 10,000 keys per request)
        keys = short_links.map do |link|
          {
            key: link.slug,
            value: {
              target_url: link.target_url,
              target_type: link.target_type,
              active: link.active?,
              expires_at: link.expires_at&.iso8601,
              max_clicks: link.max_clicks,
              click_count: link.click_count,
              utm_source: link.utm_source,
              utm_medium: link.utm_medium,
              utm_campaign: link.utm_campaign
            }.to_json
          }
        end

        # Bulk write in batches of 10,000
        keys.each_slice(10_000) do |batch|
          response = HTTParty.put(
            "#{base_url}/bulk",
            body: batch.to_json,
            headers: auth_headers
          )
          raise "Bulk sync failed: #{response.body}" unless response.success?
        end

        short_links.each { |l| l.update!(last_synced_at: Time.current) }
        Result.success(short_links)
      end

      private

      def base_url
        "https://api.cloudflare.com/client/v4/accounts/#{@account_id}/storage/kv/namespaces/#{@namespace_id}"
      end

      def auth_headers
        {
          'Authorization' => "Bearer #{@api_token}",
          'Content-Type' => 'application/json'
        }
      end
    end
  end
end
```

### Model Callbacks for Auto-Sync

```ruby
# app/models/platform/short_link.rb
module Platform
  class ShortLink < Platform::ApplicationRecord
    after_commit :sync_to_cloudflare, on: %i[create update]
    after_commit :delete_from_cloudflare, on: :destroy

    private

    def sync_to_cloudflare
      Platform::Cloudflare::SyncService.new.sync_link(self)
    rescue => e
      Rails.logger.error "Cloudflare sync failed for #{slug}: #{e.message}"
      # Don't raise — link is still valid in Rails even if sync fails
    end

    def delete_from_cloudflare
      Platform::Cloudflare::SyncService.new.delete_link(slug)
    rescue => e
      Rails.logger.error "Cloudflare delete failed for #{slug}: #{e.message}"
    end
  end
end
```

### Webhook Receiver

```ruby
# app/controllers/platform/webhooks/clicks_controller.rb
module Platform
  module Webhooks
    class ClicksController < Platform::ApplicationController
      skip_before_action :authenticate_user
      skip_before_action :authorize_action!
      skip_before_action :verify_authenticity_token

      def create
        # Verify webhook signature
        unless valid_signature?
          return render_error("Invalid signature", status: :unauthorized)
        end

        # Process click asynchronously
        ShortLinkClickJob.perform_later(click_params)

        head :ok
      end

      private

      def click_params
        params.permit(
          :slug, :referrer, :user_agent, :ip_address,
          :country, :city, :colo, :timestamp,
          :utm_source, :utm_medium, :utm_campaign
        )
      end

      def valid_signature?
        signature = request.headers['X-Webhook-Signature']
        return false if signature.blank?

        expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, request.body.read)}"
        ActiveSupport::SecurityUtils.secure_compare(signature, expected)
      end

      def webhook_secret
        Rails.application.credentials.dig(:cloudflare, :webhook_secret)
      end
    end
  end
end
```

### Routes

```ruby
# config/routes.rb
namespace :platform do
  namespace :webhooks do
    post "clicks", to: "clicks#create"
  end

  resources :short_links, only: %i[index create] do
    member do
      get :analytics
      post :sync  # manual re-sync
    end
  end
end
```

---

## Deployment

### wrangler.toml

```toml
name = "digis-short-links"
main = "worker.js"
compatibility_date = "2025-01-01"

[[kv_namespaces]]
binding = "SHORT_LINKS"
id = "your-kv-namespace-id"

[vars]
ANALYTICS_WEBHOOK_URL = "https://digis.com/webhooks/clicks"

# Environment-specific
[env.production]
workers_dev = false
routes = [
  { pattern = "dig.is/*", zone_name = "dig.is" }
]

[env.staging]
workers_dev = true
```

### CI/CD (GitHub Actions)

```yaml
# .github/workflows/deploy-worker.yml
name: Deploy Short Link Worker

on:
  push:
    paths:
      - 'short-links-worker/**'
      - '.github/workflows/deploy-worker.yml'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cloudflare/wrangler-action@v3
        with:
          apiToken: ${{ secrets.CF_API_TOKEN }}
          accountId: ${{ secrets.CF_ACCOUNT_ID }}
          command: deploy --env production
```

### Initial KV Population

```ruby
# lib/tasks/short_links.rake
namespace :short_links do
  desc "Sync all short links to Cloudflare KV"
  task sync_all: :environment do
    links = Platform::ShortLink.all
    result = Platform::Cloudflare::SyncService.new.bulk_sync(links)
    puts "Synced #{result.value.count} links"
  end
end
```

---

## Analytics Pipeline

```
Cloudflare Worker (edge)
  ↓ POST /webhooks/clicks (signed)
Rails Webhooks::ClicksController
  ↓ enqueue job
ShortLinkClickJob
  ↓ create record
short_link_clicks table
```

### Click Job

```ruby
# app/jobs/platform/short_link_click_job.rb
module Platform
  class ShortLinkClickJob < ApplicationJob
    queue_as :analytics
    retry_on StandardError, wait: :exponentially_longer, attempts: 3

    def perform(params)
      link = Platform::ShortLink.find_by(slug: params[:slug])
      return unless link

      device = parse_device(params[:user_agent])

      link.clicks.create!(
        referrer: params[:referrer],
        user_agent: params[:user_agent],
        ip_address: params[:ip_address],
        country: params[:country],
        city: params[:city],
        colo: params[:colo],
        device_type: device[:type],
        clicked_at: params[:timestamp] || Time.current
      )

      # Sync click count back to KV (eventual consistency)
      link.increment!(:click_count)
    end

    private

    def parse_device(user_agent)
      return { type: "unknown" } if user_agent.blank?
      ua = user_agent.downcase
      if ua.include?("mobile") || ua.include?("android") || ua.include?("iphone")
        { type: "mobile" }
      elsif ua.include?("tablet") || ua.include?("ipad")
        { type: "tablet" }
      else
        { type: "desktop" }
      end
    end
  end
end
```

---

## Cloudflare KV Sync Delay

Cloudflare KV has **eventual consistency** with ~5 minute propagation delay globally. This means:

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| New link created | Takes ~5 min to work on dig.is | Show "link will be active shortly" message |
| Link updated | Old target serves for ~5 min | Acceptable for most use cases |
| Link deleted | Still works for ~5 min | Acceptable — short window |
| Click count | KV count may differ from Rails | Rails is source of truth; KV is cache |

**For instant propagation**: Use `metadata: { ttl: 0 }` on KV writes for immediate consistency in the edge location that received the write. Other locations may still have ~5 min delay.

---

## Security

| Concern | Mitigation |
|---------|-----------|
| Webhook spoofing | HMAC-SHA256 signature verification |
| KV tampering | Cloudflare API token scoped to KV namespace only |
| Open redirect | Only redirect to known targets or validated HTTPS URLs |
| Abuse | Rate limit link creation in Rails; Cloudflare WAF on dig.is |
| Analytics spam | Validate payload schema; ignore malformed webhooks |

---

## Cost Breakdown

| Component | Free Tier | Paid |
|-----------|-----------|------|
| Cloudflare Workers | 100K req/day | $5/10M req |
| Cloudflare KV | 1GB storage, 100K reads/day | $0.50/GB, $0.50/1M reads |
| Cloudflare DNS | Free | Free |
| Rails webhook endpoint | Included in existing server | — |
| **Total** | **$0/month** | **~$5-10/month at scale** |

---

## File Inventory

### New Files
- `short-links-worker/worker.js` — Cloudflare Worker code
- `short-links-worker/wrangler.toml` — Worker configuration
- `.github/workflows/deploy-worker.yml` — CI/CD deployment
- `app/services/platform/cloudflare/sync_service.rb` — KV sync
- `app/controllers/platform/webhooks/clicks_controller.rb` — Webhook receiver
- `app/jobs/platform/short_link_click_job.rb` — Analytics processing
- `app/models/platform/short_link.rb` — Model with sync callbacks
- `app/models/platform/short_link_click.rb` — Analytics model
- `db/migrate/XXXX_create_short_links.rb`
- `db/migrate/XXXX_create_short_link_clicks.rb`
- `lib/tasks/short_links.rake` — Initial sync task
- `test/models/platform/short_link_test.rb`
- `test/controllers/platform/webhooks/clicks_controller_test.rb`
- `test/services/platform/cloudflare/sync_service_test.rb`

### Modified Files
- `config/routes.rb` — Add webhook and short link admin routes
- `config/credentials.yml.enc` — Add Cloudflare credentials

---

## Comparison: Option A vs Option B

| Aspect | Option A (Same Rails App) | Option B (Cloudflare Workers) |
|--------|--------------------------|-------------------------------|
| **Latency** | 50-100ms | 3-5ms |
| **Infrastructure** | Zero extra | Cloudflare account ($0 free) |
| **Complexity** | Low | Medium (new toolchain) |
| **Isolation** | Shares Rails load | Fully isolated |
| **Uptime** | Tied to Rails | Independent (99.99%) |
| **Analytics** | Direct DB write | Webhook → async job |
| **Sync delay** | N/A (same DB) | ~5 min KV propagation |
| **Team skills** | Ruby only | Ruby + JavaScript |
| **Cost at scale** | Rails server scaling | $5-10/month |
| **Global performance** | Single region | 300+ edge locations |

**Recommendation**: Option B (Cloudflare Workers) is the best choice for a ticketing platform targeting Ethiopia and beyond. The edge network ensures fast redirects globally, the free tier covers most use cases, and the isolation means short links work even during Rails maintenance or outages.
