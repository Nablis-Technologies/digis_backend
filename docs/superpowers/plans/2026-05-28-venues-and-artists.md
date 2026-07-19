# Plan: Events::Venue and Events::Artist Models

## Context

The Events module needs foundational reference data entities — Venues and Artists — before Events themselves can be built. Admin creates these as shared reference data; organizations reference them on events. The domain module generator can scaffold both, then we customize fields per the architecture doc.

## Scope

- `Events::Venue` — admin-managed, global shared data, no org ownership
- `Events::Artist` — admin-managed, global shared data (like Spotify artists)
- No `EventArtists` join table (no Event model yet)
- Both in `Events` namespace

---

## Step 1: Generate Events::Venue

Use the domain module generator:

```bash
rails generate domain_module Events::Venue \
  name:string \
  description:text \
  address:string \
  city:string \
  country:string \
  latitude:decimal \
  longitude:decimal \
  capacity:integer \
  amenities:jsonb \
  contact_phone:string \
  contact_email:string \
  website_url:string \
  verified:boolean \
  active:boolean \
  --slug-source=name
```

Then customize:
- Remove `metadata` from migration if generator adds it (not needed for venues)
- Add `active` default `true` in migration
- Add `verified` default `false` in migration
- Ensure `validates :name, presence: true, uniqueness: true` in model
- Add scopes: `by_city`, `by_country`, `verified`, `active`
- Add `ransackable_attributes` for search/filter

## Step 2: Generate Events::Artist

```bash
rails generate domain_module Events::Artist \
  name:string \
  description:text \
  image_url:string \
  genres:jsonb \
  social_links:jsonb \
  verified:boolean \
  active:boolean \
  --slug-source=name
```

Then customize:
- Remove `metadata` from migration if generator adds it
- Add `active` default `true` in migration
- Add `verified` default `false` in migration
- Ensure `validates :name, presence: true, uniqueness: true` in model
- Add scopes: `by_genre`, `verified`, `active`
- Add `ransackable_attributes` for search/filter

## Step 3: Customize Policies

Both models follow the same policy pattern:

- **Admin-only create/update/destroy**: only `super_admin` and `admin` roles can mutate
- **Read access for all**: anyone with `venue.index`/`venue.show` or `artist.index`/`artist.show` can read
- **VISIBILITY hash** restructured to action-first nesting (matching the pattern from Admin policies)

Update `Events::VenuePolicy` and `Events::ArtistPolicy` accordingly.

## Step 4: Add Permissions to Seeds

Add to `db/seeds.rb`:

```ruby
# Venue permissions
{ code: "venue.index",   resource: "venue", action: "index",   namespace: "events" },
{ code: "venue.show",    resource: "venue", action: "show",    namespace: "events" },
{ code: "venue.create",  resource: "venue", action: "create",  namespace: "events" },
{ code: "venue.update",  resource: "venue", action: "update",  namespace: "events" },
{ code: "venue.destroy", resource: "venue", action: "destroy", namespace: "events" },

# Artist permissions
{ code: "artist.index",   resource: "artist", action: "index",   namespace: "events" },
{ code: "artist.show",    resource: "artist", action: "show",    namespace: "events" },
{ code: "artist.create",  resource: "artist", action: "create",  namespace: "events" },
{ code: "artist.update",  resource: "artist", action: "update",  namespace: "events" },
{ code: "artist.destroy", resource: "artist", action: "destroy", namespace: "events" },
```

Assign `venue.*` and `artist.*` to SUPER_ADMIN, ADMIN, and CORE_ADMIN roles.

## Step 5: Add Seed Data

Add sample venues and artists to seeds for testing:

```ruby
# Venues
Events::Venue.create!(name: "Addis Arena", address: "Bole, Addis Ababa", city: "Addis Ababa", country: "Ethiopia", capacity: 15000, verified: true)
Events::Venue.create!(name: "Hilton Conference Hall", address: "Arat Kilo, Addis Ababa", city: "Addis Ababa", country: "Ethiopia", capacity: 2000, verified: true)

# Artists
Events::Artist.create!(name: "Burna Boy", genres: ["afrobeats", "dancehall"], verified: true)
Events::Artist.create!(name: "Davido", genres: ["afrobeats", "highlife"], verified: true)
Events::Artist.create!(name: "Teddy Afro", genres: ["ethio-jazz", "pop"], verified: true)
```

## Step 6: Add Routes

Add to `config/routes.rb`:

```ruby
namespace :events do
  resources :venues
  resources :artists
end
```

## Step 7: Update Tests

### Model Tests
- `test/models/events/venue_test.rb` — validations, scopes, slugable
- `test/models/events/artist_test.rb` — validations, scopes, slugable

### Integration Tests (using `resource_test`)
- `test/integration/events/venues_test.rb` — CRUD + policy matrix + audit
- `test/integration/events/artists_test.rb` — CRUD + policy matrix + audit

### Custom Tests
- Venue: uniqueness of name, slug generation, verified/active defaults
- Artist: uniqueness of name, slug generation, genre filtering, verified/active defaults

## Step 8: Update Postman Collection

Add `Venues` and `Artists` folders under `Events`:
- List (GET /events/venues, /events/artists)
- Create (POST /events/venues, /events/artists)
- Show (GET /events/venues/:id, /events/artists/:id)
- Update (PATCH /events/venues/:id, /events/artists/:id)
- Destroy (DELETE /events/venues/:id, /events/artists/:id)

## Step 9: Write Spec

Create `docs/superpowers/specs/2026-05-28-venues-and-artists.md` documenting the design decisions.

## Step 10: Verify

- Run `rails db:migrate` — should pass
- Run `rails test` — should pass (0 failures, 0 errors)
- Verify seeds load with `rails db:seed`

---

## Critical Files
- `lib/generators/domain_module/domain_module_generator.rb` — the generator
- `app/models/events/category.rb` — pattern reference for Events models
- `app/controllers/events/categories_controller.rb` — pattern reference for Events controllers
- `app/policies/events/category_policy.rb` — pattern reference for Events policies
- `app/serializers/events/category_serializer.rb` — pattern reference for Events serializers
- `db/seeds.rb` — permissions and seed data
- `config/routes.rb` — route registration
