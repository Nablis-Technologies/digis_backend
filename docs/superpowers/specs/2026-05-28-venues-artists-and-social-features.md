# Spec: Venues, Artists, and Social Features

**Date**: 2026-05-28
**Status**: Draft
**Author**: opencode

---

## Overview

This spec covers the public catalog and admin management for event venues and artists, plus the social follow system:

1. **Events::Category** — Event categories (public catalog + admin management)
2. **Events::Venue** — Venue entities with profile image and photo gallery
3. **Events::Artist** — Artist profiles with profile image (like Spotify artists)
4. **Core::Follow** — Polymorphic follow system enabling social feeds
5. **Core::SocialLinkable** — Shared concern for structured social media links (jsonb field pattern)

**Note**: Organizations follow/social features are in a separate spec.

---

## 1. Events::Category

### Purpose
Categories are classification labels for events (e.g., "Concert", "Conference", "Festival"). Public users can browse categories; admins can create/update/delete them.

### Existing Schema

Already exists in `events_categories` table with:
- `name`, `slug`, `description`, `metadata`, `active`
- Unique indexes on `slug` and `name`

### Existing Serializers

**Owner-side serializer** (used by admin controller — includes `audit_logs` for admin include support):

Already exists at `app/serializers/events/category_serializer.rb`:
```ruby
class Events::CategorySerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
  has_many :audit_logs, serializer: Core::AuditLogSerializer
end
```

No changes needed to this serializer.

**Public serializers** (used by public catalog endpoints — no `has_many :audit_logs` to prevent exposing audit data):

Add at `app/serializers/events/public/category_list_serializer.rb`:
```ruby
class Events::Public::CategoryListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :slug
end
```

Add at `app/serializers/events/public/category_detail_serializer.rb`:
```ruby
class Events::Public::CategoryDetailSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
end
```

**Design note**: Public controllers bypass Pundit (`policy_for_data` returns nil), making serializer declarations the effective contract. Dedicated public serializers prevent associations like `audit_logs` from being reachable via `?include=`. Only declare associations on public serializers that are explicitly safe for unauthenticated exposure.

### Public Base Controller

Create a thin public base controller that mirrors Core::ApplicationController but without mandatory auth/Pundit:

```ruby
# app/controllers/public/application_controller.rb
module Public
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable
    include Core::Pagination

    # Consistent error handling (same as Core::ApplicationController)
    rescue_from ActiveRecord::RecordNotFound do |error|
      model_name = error.model&.constantize&.model_name&.human&.downcase || "resource"
      render_error(I18n.t(:"errors.not_found", model: model_name), status: :not_found)
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      render_error(errors: error.record.errors, status: :unprocessable_entity)
    end

    private

    # No Pundit — public endpoints don't require authorization
    def policy_for_data(data)
      nil
    end
  end
end
```

This provides:
- `render_success` / `render_error` (via JsonResponse)
- `current_user` when authenticated (via Authenticatable)
- `apply_pagination` (via Pagination)
- Consistent error handling (rescue_from RecordNotFound, RecordInvalid)
- No mandatory auth — controllers add `before_action :authenticate_user` for specific actions
- No Pundit — `policy_for_data` returns nil so VISIBILITY is skipped for public endpoints

**Note on VISIBILITY**: Public controllers bypass Pundit (`policy_for_data` returns nil), so the VISIBILITY hashes in policies are NOT enforced for public endpoints. The public response shape is controlled by the serializer (which attributes are defined). VISIBILITY is only enforced for admin endpoints that use `Admin::ApplicationController` with full Pundit integration.

### Policy

Update existing policy to use `allowed?()` for RBAC consistency (replaces direct role checks).

**Breaking change**: `destroy?` changes from SUPER_ADMIN-only (`user.has_role?("SUPER_ADMIN")`) to permission-based (`allowed?(:destroy)`). ADMIN and CORE_ADMIN roles will gain destroy capability if permissions are seeded.

```ruby
module Events
  class CategoryPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    def create?
      allowed?(:create)
    end

    def update?
      allowed?(:update)
    end

    def destroy?
      allowed?(:destroy)
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name description slug metadata active], include: [] },
        admin: { include: [ :audit_logs ] }
      }
    }
    # Note: VISIBILITY only governs serialized output (response attributes).
    # Write contract (permitted params) is defined in controller's #model_params.
    # Public endpoints bypass Pundit (policy_for_data returns nil), so VISIBILITY
    # is only enforced for admin endpoints using Admin::ApplicationController.

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")
        scope.active
      end
    end
  end
end
```

### Admin Policies

Admin controllers require `Admin::*Policy` classes. These delegate to the existing policy but are resolved by `Admin::ApplicationController`:

```ruby
module Admin
  class CategoryPolicy < Events::CategoryPolicy
    # Inherits all behavior from Events::CategoryPolicy
    # Admin::ApplicationController resolves this by name
  end

  class VenuePolicy < Events::VenuePolicy
    # Inherits all behavior from Events::VenuePolicy
    # Admin::ApplicationController resolves this by name
  end

  class ArtistPolicy < Events::ArtistPolicy
    # Inherits all behavior from Events::ArtistPolicy
    # Admin::ApplicationController resolves this by name
  end
end
```

### Controllers

Split into public catalog and admin management:

**Public controller** (`Events::CategoriesController`) — No authentication required. Uses dedicated public serializer (see Existing Serializers note):

```ruby
module Events
  class CategoriesController < Public::ApplicationController
    # GET /events/categories
    def index
      categories = Events::Category.active
      categories = paginated_request? ? apply_pagination(categories) : categories.limit(25)
      render_success(data: categories, serializer_options: { serializer: Events::Public::CategoryListSerializer })
    end

    # GET /events/categories/:id
    def show
      category = Events::Category.find(params[:id])
      render_success(data: category, serializer_options: { serializer: Events::Public::CategoryDetailSerializer })
    end
  end
end
```

**Admin controller** (`Admin::CategoriesController`) — Full CRUD with RBAC, uses `Core::Common`:

```ruby
module Admin
  class CategoriesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Category

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:category).permit(:name, :description, :slug, :active, metadata: {})
    end
  end
end
```

### Routes

**Public routes:**
```ruby
namespace :events do
  resources :categories, only: %i[index show]
end
```

**Admin routes:**
```ruby
namespace :admin do
  resources :categories, except: %i[new edit]
end
```

---

## 2. Events::Venue

### Purpose
Venues are first-class entities representing physical locations where events take place. Admin creates them as shared reference data; organizations reference them on events.

### Database Schema

```ruby
create_table :events_venues, id: :uuid do |t|
  t.string   :name,           null: false
  t.string   :slug,           null: false
  t.text     :description
  t.string   :address
  t.string   :city
  t.string   :country
  t.decimal  :latitude,       precision: 10, scale: 6
  t.decimal  :longitude,      precision: 10, scale: 6
  t.integer  :capacity
  t.jsonb    :amenities,      default: []    # ["parking", "wifi", "bar", "vip_lounge"]
  t.jsonb    :social_links,   default: {}    # { instagram: "url", twitter: "url", ... }
  t.string   :contact_phone
  t.string   :contact_email
  t.string   :website_url
  t.boolean  :verified,       default: false
  t.boolean  :active,         default: true
  t.integer  :followers_count, default: 0, null: false
  t.jsonb    :metadata,       default: {}
  t.timestamps
end

add_index :events_venues, :slug, unique: true
add_index :events_venues, :city
add_index :events_venues, :country
add_index :events_venues, :verified
add_index :events_venues, :active
```

### Active Storage

```ruby
has_one_attached  :profile      # Main profile image (hero image)
has_many_attached :photos       # Gallery images (max 10)
```

**Variants** (generated on demand when first accessed):
- `thumbnail`: 300x300 (for list views, search results)
- `medium`: 800x800 (for detail pages)

**Validation**: `profile` must be present on create. `photos` limited to 10 (enforced on update; on create, photos are added after saving the record).

### Model

```ruby
module Events
  class Venue < Events::ApplicationRecord
    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached  :profile
    has_many_attached :photos

    validates :name, presence: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }
    validate  :profile_must_be_attached, on: :create
    validate  :photos_count_within_limit

    scope :by_city, ->(city) { where(city: city) }
    scope :by_country, ->(country) { where(country: country) }
    scope :verified, -> { where(verified: true) }
    scope :active, -> { where(active: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[name city country verified active created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end

    private

    def profile_must_be_attached
      errors.add(:profile, "must be attached") unless profile.attached?
    end

    def photos_count_within_limit
      errors.add(:photos, "maximum 10 photos allowed") if photos.count > 10
    end
  end
end
```

### Policy

```ruby
module Events
  class VenuePolicy < Core::ApplicationPolicy
    # Admin-only create/update/destroy
    # Read access for everyone (including guests)

    def index?
      true
    end

    def show?
      true
    end

    def create?
      allowed?(:create)
    end

    def update?
      allowed?(:update)
    end

    def destroy?
      allowed?(:destroy)
    end

    def follow?
      true  # Consumer action — everyone can follow public profiles
    end

    def unfollow?
      true  # Consumer action — everyone can unfollow
    end

    def followers?
      true  # Consumer action — everyone can view followers
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description address city country capacity verified active], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name slug description address city country latitude longitude capacity amenities social_links contact_phone contact_email website_url verified active followers_count], include: [] },
        admin: { include: [] }
      }
    }
    # Note: VISIBILITY only governs serialized output (response attributes).
    # Write contract (permitted params) is defined in controller's #model_params.

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.active
      end
    end
  end
end
```

### Serializers

**Important**: Ensure `config.routes.default_url_options` is set in all environments for proper URL generation:

```ruby
# config/environments/development.rb
config.routes.default_url_options = { host: "localhost", port: 3000 }

# config/environments/production.rb
config.routes.default_url_options = { host: "yourdomain.com" }

# config/environments/test.rb
config.routes.default_url_options = { host: "example.com" }
```

**Admin/owner-side serializer** (used by admin controller — full detail):

```ruby
class Events::VenueSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :address, :city, :country,
             :latitude, :longitude, :capacity, :amenities, :social_links,
             :contact_phone, :contact_email, :website_url,
             :verified, :active, :created_at, :updated_at

  attribute :profile_url do
    object.profile.attached? ? url_for(object.profile) : nil
  end

  attribute :profile_urls do
    {
      original: object.profile.attached? ? url_for(object.profile) : nil,
      thumbnail: object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [300, 300])) : nil,
      medium: object.profile.attached? ? url_for(object.profile.variant(resize_to_fill: [800, 800])) : nil
    }
  end

  attribute :gallery_urls do
    object.photos.map do |photo|
      {
        original: url_for(photo),
        thumbnail: url_for(photo.variant(resize_to_fill: [300, 300])),
        medium: url_for(photo.variant(resize_to_fill: [800, 800]))
      }
    end
  end

  attribute :follower_count do
    object.followers_count
  end
end
```

  **Public list serializer** (index — lighter payload, no geo details or contact info):

  ```ruby
  class Events::Public::VenueListSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    attributes :id, :name, :slug, :description, :address, :city, :country,
               :capacity, :verified, :active

    attribute :profile_urls do
    {
      thumbnail: venue.profile.attached? ? url_for(venue.profile.variant(resize_to_fill: [300, 300])) : nil,
      medium: venue.profile.attached? ? url_for(venue.profile.variant(resize_to_fill: [800, 800])) : nil
    }
  end
end
```

**Public detail serializer** (show — full public detail with geo, contact, and social):

```ruby
class Events::Public::VenueDetailSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :address, :city, :country,
             :latitude, :longitude, :capacity, :amenities, :social_links,
             :contact_phone, :contact_email, :website_url,
             :verified, :active

  attribute :profile_url do |venue|
    venue.profile.attached? ? url_for(venue.profile) : nil
  end

  attribute :profile_urls do |venue|
    {
      original: venue.profile.attached? ? url_for(venue.profile) : nil,
      thumbnail: venue.profile.attached? ? url_for(venue.profile.variant(resize_to_fill: [300, 300])) : nil,
      medium: venue.profile.attached? ? url_for(venue.profile.variant(resize_to_fill: [800, 800])) : nil
    }
  end

  attribute :gallery_urls do |venue|
    venue.photos.map do |photo|
      {
        original: url_for(photo),
        thumbnail: url_for(photo.variant(resize_to_fill: [300, 300])),
        medium: url_for(photo.variant(resize_to_fill: [800, 800]))
      }
    end
  end

  attribute :follower_count do |venue|
    venue.followers_count
  end
end
```

**Design note**: Public serializers are explicitly selected per action. The list serializer omits geo coordinates, contact info, social links, and gallery — fields that are unnecessary for browsing. The detail serializer includes the full public contract. This replaces the previous pattern where both actions relied on a single serializer with Pundit VISIBILITY to differentiate shapes (VISIBILITY is bypassed on public endpoints — see Anchored Summary §1).

### Controllers

Split into public catalog and admin management:

**Public controller** (`Events::VenuesController`) — Public read, authenticated follow:

```ruby
module Events
  class VenuesController < Public::ApplicationController
    include Core::FollowableActions

    # GET /events/venues
    def index
      venues = Events::Venue.active
      venues = paginated_request? ? apply_pagination(venues) : venues.limit(25)
      render_success(data: venues, serializer_options: { serializer: Events::Public::VenueListSerializer })
    end

    # GET /events/venues/:id
    def show
      venue = Events::Venue.find(params[:id])
      render_success(data: venue, serializer_options: { serializer: Events::Public::VenueDetailSerializer })
    end

    private

    def followable_class
      Events::Venue
    end
  end
end
```

**Admin controller** (`Admin::VenuesController`) — Full CRUD with RBAC, uses `Core::Common`:

```ruby
module Admin
  class VenuesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Venue

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:venue).permit(
        :name, :description, :address, :city, :country,
        :latitude, :longitude, :capacity, :contact_phone,
        :contact_email, :website_url, :verified, :active,
        :profile, photos: [], amenities: [], social_links: {}
      )
    end
  end
end
```

### Routes

**Public routes:**
```ruby
namespace :events do
  resources :venues, only: %i[index show] do
    member do
      post :follow
      post :unfollow
      get :followers
    end
  end
end
```

**Admin routes:**
```ruby
namespace :admin do
  resources :venues, except: %i[new edit]
end
```

**User following list** — separate route:

```ruby
scope module: :core do
  get "users/:user_id/following", to: "follows#following"
end
```

**Social feed** (deferred):

```ruby
scope module: :core do
  get "feed", to: "feed#index"
end
```

---

## 3. Events::Artist

### Purpose
Artists are first-class entities representing performers/musicians (like Spotify artists). Admin creates them as shared reference data; organizations reference them on events.

### Database Schema

```ruby
create_table :events_artists, id: :uuid do |t|
  t.string   :name,           null: false
  t.string   :slug,           null: false
  t.text     :description
  t.string   :image_url       # External image URL (Spotify, etc.)
  t.jsonb    :genres,         default: []    # ["afrobeats", "dancehall", "ethio-jazz"]
  t.jsonb    :social_links,   default: {}    # { instagram: "url", spotify: "url", ... }
  t.boolean  :verified,       default: false
  t.boolean  :active,         default: true
  t.integer  :followers_count, default: 0, null: false
  t.jsonb    :metadata,       default: {}    # { spotify_id: "...", apple_music_id: "..." }
  t.timestamps
end

add_index :events_artists, :slug, unique: true
add_index :events_artists, :verified
add_index :events_artists, :active
add_index :events_artists, :genres, using: :gin
```

### Active Storage

```ruby
has_one_attached :profile   # Profile image
```

**Variants** (generated on demand when first accessed):
- `thumbnail`: 300x300 (for list views)
- `medium`: 800x800 (for detail pages)

**Note**: Artists also have `image_url` for external images (Spotify CDN, etc.). If `profile` is attached, it takes precedence over `image_url`.

### Model

```ruby
module Events
  class Artist < Events::ApplicationRecord
    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached :profile

    validates :name, presence: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

    scope :by_genre, ->(genre) { where("genres @> ?", [genre].to_json) }
    scope :verified, -> { where(verified: true) }
    scope :active, -> { where(active: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[name verified active created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      []
    end
  end
end
```

### Policy

Same pattern as Venue — admin-only CRUD, read for all (including guests):

```ruby
module Events
  class ArtistPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    def create?
      allowed?(:create)
    end

    def update?
      allowed?(:update)
    end

    def destroy?
      allowed?(:destroy)
    end

    def follow?
      true  # Consumer action — everyone can follow public profiles
    end

    def unfollow?
      true  # Consumer action — everyone can unfollow
    end

    def followers?
      true  # Consumer action — everyone can view followers
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description genres verified active], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name slug description image_url genres social_links verified active followers_count], include: [] },
        admin: { include: [] }
      }
    }
    # Note: VISIBILITY only governs serialized output (response attributes).
    # Write contract (permitted params) is defined in controller's #model_params.

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.active
      end
    end
  end
end
```

### Serializers

**Admin/owner-side serializer** (used by admin controller — full detail):

```ruby
class Events::ArtistSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :genres, :social_links,
             :verified, :active, :created_at, :updated_at

  attribute :profile_url do |artist|
    if artist.profile.attached?
      url_for(artist.profile)
    else
      artist[:image_url]
    end
  end

  attribute :profile_urls do |artist|
    if artist.profile.attached?
      {
        original: url_for(artist.profile),
        thumbnail: url_for(artist.profile.variant(resize_to_fill: [300, 300])),
        medium: url_for(artist.profile.variant(resize_to_fill: [800, 800]))
      }
    else
      { original: artist[:image_url], thumbnail: nil, medium: nil }
    end
  end

  attribute :follower_count do |artist|
    artist.followers_count
  end
end
```

**Public list serializer** (index — lighter payload, no social links or follower count):

```ruby
class Events::Public::ArtistListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :genres, :verified, :active

  attribute :profile_url do |artist|
    if artist.profile.attached?
      url_for(artist.profile.variant(resize_to_fill: [300, 300]))
    else
      artist[:image_url]
    end
  end
end
```

**Public detail serializer** (show — full public detail with social links and follower count):

```ruby
class Events::Public::ArtistDetailSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :image_url, :genres,
             :social_links, :verified, :active

  attribute :profile_url do |artist|
    if artist.profile.attached?
      url_for(artist.profile)
    else
      artist[:image_url]
    end
  end

  attribute :profile_urls do |artist|
    if artist.profile.attached?
      {
        original: url_for(artist.profile),
        thumbnail: url_for(artist.profile.variant(resize_to_fill: [300, 300])),
        medium: url_for(artist.profile.variant(resize_to_fill: [800, 800]))
      }
    else
      { original: artist[:image_url], thumbnail: nil, medium: nil }
    end
  end

  attribute :follower_count do |artist|
    artist.followers_count
  end
end
```

**Design note**: Same pattern as Venue — list/detail serializers replace a single serializer with Pundit VISIBILITY for shape differentiation. The list serializer shows only a thumbnail profile URL while the detail serializer includes full-size URLs and follower counts. See Anchored Summary §1.

### Controllers

Split into public catalog and admin management:

**Public controller** (`Events::ArtistsController`) — Public read, authenticated follow:

```ruby
module Events
  class ArtistsController < Public::ApplicationController
    include Core::FollowableActions

    # GET /events/artists
    def index
      artists = Events::Artist.active
      artists = paginated_request? ? apply_pagination(artists) : artists.limit(25)
      render_success(data: artists, serializer_options: { serializer: Events::Public::ArtistListSerializer })
    end

    # GET /events/artists/:id
    def show
      artist = Events::Artist.find(params[:id])
      render_success(data: artist, serializer_options: { serializer: Events::Public::ArtistDetailSerializer })
    end

    private

    def followable_class
      Events::Artist
    end
  end
end
```

**Admin controller** (`Admin::ArtistsController`) — Full CRUD with RBAC, uses `Core::Common`:

```ruby
module Admin
  class ArtistsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Artist

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:artist).permit(
        :name, :description, :image_url, :verified, :active,
        :profile, genres: [], social_links: {}
      )
    end
  end
end
```

### Routes

**Public routes:**
```ruby
namespace :events do
  resources :artists, only: %i[index show] do
    member do
      post :follow
      post :unfollow
      get :followers
    end
  end
end
```

**Admin routes:**
```ruby
namespace :admin do
  resources :artists, except: %i[new edit]
end
```

---

## 4. Core::Follow (Polymorphic Follow System)

### Purpose
Enables users to follow venues and artists. Supports follower counts, following lists, and a social feed (timeline of events from followed entities).

**Note**: Organization follows are in a separate spec.

### Database Schema

```ruby
create_table :core_follows, id: :uuid do |t|
  t.uuid     :follower_id,    null: false
  t.uuid     :followable_id,  null: false
  t.string   :followable_type, null: false   # "Events::Venue", "Events::Artist"
  t.datetime :followed_at,    null: false
  t.timestamps
end

add_index :core_follows, [:follower_id, :followable_id, :followable_type], unique: true, name: "index_follows_uniqueness"
add_index :core_follows, [:followable_id, :followable_type], name: "index_follows_followable"
add_index :core_follows, :follower_id
```

### Model

```ruby
module Core
  class Follow < Core::ApplicationRecord
    belongs_to :follower, class_name: "Core::User"
    belongs_to :followable, polymorphic: true, counter_cache: :followers_count

    before_validation { self.followed_at ||= Time.current }

    validates :follower_id, uniqueness: { scope: [:followable_id, :followable_type] }

    scope :for_type, ->(type) { where(followable_type: type) }
  end
end
```

**User model association** — Add to `Core::User`:

```ruby
has_many :active_follows, class_name: "Core::Follow", foreign_key: "follower_id", dependent: :destroy
```

### Concern: Core::Followable

Shared concern for any model that can be followed:

```ruby
module Core
  module Followable
    extend ActiveSupport::Concern

    included do
      has_many :follows, as: :followable, class_name: "Core::Follow", dependent: :destroy
      has_many :followers, through: :follows, source: :follower
    end

    def followed_by?(user)
      return false unless user&.id
      follows.exists?(follower_id: user.id)
    end
  end
end
```

Note: The `followers_count` column is automatically maintained by Rails `counter_cache` on the `Follow` model. No manual increment/decrement needed.

### Concern: Core::FollowableActions

Shared concern eliminating duplicate follow/unfollow/followers logic across Venues, Artists, and Organizations controllers. Each controller includes this concern and defines `followable_class`:

```ruby
module Core
  module FollowableActions
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_user, only: [:follow, :unfollow]
    end

    def follow
      record = followable_class.find(params[:id])
      follow = current_user.active_follows.find_or_create_by(followable: record) do |f|
        f.followed_at = Time.current
      end
      return render_error(errors: follow.errors, status: :unprocessable_entity) unless follow.persisted?

      render_success(data: { following: true, follower_count: record.reload.followers_count })
    end

    def unfollow
      record = followable_class.find(params[:id])
      current_user.active_follows.find_by!(followable: record).destroy!
      render_success(data: { following: false, follower_count: record.reload.followers_count })
    end

    def followers
      record = followable_class.find(params[:id])
      followers = paginated_request? ? apply_pagination(record.followers) : record.followers.limit(25)
      render_success(data: followers, serializer_options: { serializer: Core::Public::UserSerializer })
    end

    private

    def followable_class
      raise NotImplementedError, "#{self.class.name} must define #followable_class"
    end
  end
end
```

**Usage** — Each controller includes the concern and defines the followable model:

```ruby
module Events
  class VenuesController < Public::ApplicationController
    include Core::FollowableActions
    # index, show — no follow/unfollow/followers boilerplate needed
    private
    def followable_class
      Events::Venue
    end
  end
end
```

**Note on race-condition handling** (from `find_or_create_by` without `!`): Using `find_or_create_by` (without `!`) avoids `ActiveRecord::RecordInvalid` from the model-level uniqueness validation. If creation fails (e.g., DB unique constraint), the unsaved record is returned with errors. The `unless follow.persisted?` check catches this and returns 422. This is safe because:
1. The DB unique constraint prevented a duplicate
2. The counter_cache is already correct
3. The user's intent (to follow) is already satisfied

### Controller: Core::FollowsController

Handles the `following` list (what a user follows). Follow/unfollow/followers are member actions on each resource controller via `Core::FollowableActions` (see Routes section).

Access is explicitly scoped — only the current user can view their own following list (privacy-first default; can be changed to public access as a social feature decision):

```ruby
module Core
  class FollowsController < Core::ApplicationController
    # GET /users/:user_id/following
    def following
      user = Core::User.find(params[:user_id])
      authorize user, :following?
      following = user.active_follows.includes(:followable, :follower)
      following = paginated_request? ? apply_pagination(following) : following.limit(25)
      render_success(data: following)
    end
  end
end
```



### Social Feed (Timeline)

```ruby
# GET /feed
# Returns events from followed venues and artists (requires authentication)
class Core::FeedController < Core::ApplicationController
  skip_authorization

  def index
    followed_venue_ids = current_user.active_follows.where(followable_type: "Events::Venue").pluck(:followable_id)
    followed_artist_ids = current_user.active_follows.where(followable_type: "Events::Artist").pluck(:followable_id)

    # Build subquery of distinct event IDs to avoid duplicates from overlapping follows
    event_ids = Events::Event.where(id:
      Events::Event.where(venue_id: followed_venue_ids)
        .or(Events::Event.where(id: Events::EventArtist.where(artist_id: followed_artist_ids).select(:event_id)))
        .select(:id)
    ).distinct

    events = Events::Event.where(id: event_ids)
      .includes(:venue, :artists)
      .order(starts_at: :desc)
    events = paginated_request? ? apply_pagination(events) : events.limit(25)

    render_success(data: events)
  end
end
```

**Note**: The feed depends on the Event model. The Follow model can be built now; the feed endpoint will be added when Events are implemented.

**Performance note**: The `.or()` chain across three foreign keys may produce inefficient SQL. When implementing, consider using UNION or a subquery approach to ensure proper index usage. Alternatively, build the feed as a materialized view or use a dedicated query object that unions the three conditions.

### Routes

Follow/unfollow/followers are member actions under each resource (see Venue and Artist Routes sections above). The only additional route is the `following` list:

```ruby
scope module: :core do
  get "users/:user_id/following", to: "follows#following"
end

# Social feed (deferred)
scope module: :core do
  get "feed", to: "feed#index"
end
```

### Permissions

Follow/unfollow/followers are consumer actions — no RBAC permissions needed. Everyone can follow/unfollow public profiles.

The `following` endpoint uses Pundit via `Core::FollowPolicy#following?` which restricts access to current_user only (privacy-first). See [§8 — Follow Serializer and Policy](#8-follow-serializer-and-policy).

Only the feed needs a dedicated permission:

```ruby
# Feed permissions
{ code: "feed.index", resource: "feed", action: "index", namespace: "core" },
```

---

## 5. Social Links (jsonb field pattern)

### Purpose
Structured social media links for venues, artists, and organizations. Stored as a `jsonb` field directly on each model — no separate table. Validated against a whitelist of allowed platform keys via a shared concern.

### Supported Platforms

**Standard Social:**
- `instagram`
- `twitter` (X)
- `tiktok`
- `youtube`
- `facebook`
- `website`

**Music/Chat Platforms:**
- `spotify`
- `soundcloud`
- `apple_music`
- `telegram`
- `whatsapp`
- `discord`

### Storage Pattern

```ruby
# jsonb field on each model
t.jsonb :social_links, default: {}

# Example value:
{
  "instagram": "https://instagram.com/artist_name",
  "twitter": "https://twitter.com/artist_name",
  "spotify": "https://open.spotify.com/artist/xxxxx",
  "telegram": "https://t.me/artist_name"
}
```

### Update Semantics (Replace vs Merge)

**Default behavior**: Rails jsonb updates **replace** the entire value. When the client sends `social_links`, the entire object is replaced.

**If merge semantics are desired**, implement in the controller:

```ruby
# In controller action (e.g., update)
def update
  venue = Events::Venue.find(params[:id])
  if params[:venue][:social_links].present?
    # Merge with existing social_links
    merged = (venue.social_links || {}).merge(params[:venue][:social_links])
    params[:venue][:social_links] = merged
  end
  # ... rest of update logic
end
```

**API contract**: For this spec, we use **full replace** semantics. Clients must send the complete `social_links` object. This is simpler and avoids partial update complexity.

### Shared Concern: Core::SocialLinkable

Extract validation into a shared concern to avoid duplicating it across Venue and Artist:

```ruby
module Core
  module SocialLinkable
    extend ActiveSupport::Concern

    VALID_SOCIAL_PLATFORMS = %w[
      instagram twitter tiktok youtube facebook website
      spotify soundcloud apple_music telegram whatsapp discord
    ].freeze

    MAX_SOCIAL_LINKS = 10  # Ensure API/UI align with this limit
    MAX_URL_LENGTH = 2048

    included do
      before_validation :normalize_social_links
      validate :validate_social_links
    end

    private

    def normalize_social_links
      return if social_links.blank?
      # Normalize keys to strings, strip whitespace from values
      self.social_links = social_links.transform_keys(&:to_s).transform_values { |v| v.to_s.strip }
    end

    def validate_social_links
      return if social_links.blank?

      # Check platform count
      if social_links.size > MAX_SOCIAL_LINKS
        errors.add(:social_links, "exceeds maximum of #{MAX_SOCIAL_LINKS} platforms")
        return
      end

      # Check for invalid platform keys
      invalid_keys = social_links.keys - VALID_SOCIAL_PLATFORMS
      if invalid_keys.any?
        errors.add(:social_links, "contains unsupported platforms: #{invalid_keys.join(', ')}")
        return
      end

      # Validate URL format for each link
      social_links.each do |platform, url|
        next if url.blank?
        unless valid_url?(url)
          errors.add(:social_links, "#{platform} must be a valid URL")
        end
      end
    end

    def valid_url?(url)
      return false if url.length > MAX_URL_LENGTH
      uri = URI.parse(url)
      return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return false if uri.host.blank? || uri.host.include?(" ")
      true
    rescue URI::InvalidURIError
      false
    end
  end
end
```

**Usage in models:**

```ruby
class Events::Venue < ApplicationRecord
  include Core::SocialLinkable
  # ...
end

class Events::Artist < ApplicationRecord
  include Core::SocialLinkable
  # ...
end
```

---

## 6. Implementation Order

### Phase 1: Setup
1. Run `rails active_storage:install` and `rails db:migrate`
2. Verify `active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records` tables exist
3. Verify `image_processing` gem is in Gemfile (required for Active Storage variants)
4. Create `Public::ApplicationController` — base for public catalog endpoints (no auth)
5. Seed permissions for categories, venues, artists (required for `allowed?()` in policies):
   - `category.create`, `category.update`, `category.destroy`
   - `venue.create`, `venue.update`, `venue.destroy`
   - `artist.create`, `artist.update`, `artist.destroy`
6. Assign permissions to SUPER_ADMIN, ADMIN, and CORE_ADMIN roles

### Phase 2: Events::Category (Refactor to Public/Admin Split)
1. Create `Events::Public::CategoryListSerializer` — public index (id, name, slug)
2. Create `Events::Public::CategoryDetailSerializer` — public show (all public attributes)
3. Update `Events::CategoriesController` — inherit from `Public::ApplicationController` (index, show only), use per-action list/detail serializers
4. Create `Admin::CategoriesController` — admin CRUD (uses Core::Common)
5. **Replace** existing `events/categories` route with public/admin split (must remove old route block)
6. Update `Events::CategoryPolicy` — add VISIBILITY for index
7. Write integration tests:
   - Public: index and show without authentication
   - Admin: CRUD with RBAC via resource_test

### Phase 3: Events::Venue
1. Generate via domain module generator
2. Customize fields per schema above
3. Add Active Storage attachments (`profile`, `photos`)
4. Add custom validations (`profile_must_be_attached`, `photos_count_within_limit`)
5. Add `Core::SocialLinkable` concern (shared validation)
6. Include `Core::SocialLinkable` in Venue model
7. Add `has_many :follows, as: :followable` via Followable concern
8. Create `Events::Public::VenueListSerializer` — public index (no geo/contact/social)
9. Create `Events::Public::VenueDetailSerializer` — public show (full public detail)
10. Write model tests (validations, scopes, slugable, social links validation)
11. Write integration tests:
    - Public: index (uses VenueListSerializer), show (uses VenueDetailSerializer)
    - Admin: CRUD + policy matrix + audit via resource_test
    - Dedicated tests for Active Storage profile/photos upload (multipart requests)
    - Dedicated tests for social links validation
12. Add seed data

### Phase 4: Events::Artist
1. Generate via domain module generator
2. Customize fields per schema above
3. Add Active Storage attachment (`profile`)
4. Include `Core::SocialLinkable` in Artist model
5. Add genres jsonb field + GIN index
6. Add `has_many :follows, as: :followable` via Followable concern
7. Create `Events::Public::ArtistListSerializer` — public index (thumbnail only)
8. Create `Events::Public::ArtistDetailSerializer` — public show (full URLs, follower count)
9. Write model tests (validations, scopes, slugable, genre filtering, social links)
10. Write integration tests:
    - Public: index (uses ArtistListSerializer), show (uses ArtistDetailSerializer)
    - Admin: CRUD + policy matrix + audit via resource_test
    - Dedicated tests for Active Storage profile upload (multipart requests)
    - Dedicated tests for social links validation
11. Add seed data

### Phase 5: Core::Follow + Followable Actions Concern
1. Create `Core::Follow` model with migration
2. Create `Core::Followable` concern (model-level: `has_many :follows`, `has_many :followers`, `followed_by?`)
3. Create `Core::FollowableActions` concern (controller-level: shared follow/unfollow/followers actions)
4. Update `Core::FollowPolicy` — add `following?` with explicit privacy guard
5. Include Followable in Venue, Artist models
6. Include FollowableActions in VenuesController, ArtistsController, OrganizationsController
7. Create `Core::FollowsController` with `following` action (uses `authorize user, :following?`)
8. Write integration tests:
   - Follow, unfollow, duplicate follow, follower count, following list
   - Verify `following` is restricted to current_user (privacy-first)
9. Add permissions to seeds

### Phase 6: Social Feed (Deferred)
- Build `Core::FeedController` when Event model exists
- Query events from followed orgs/venues/artists

### Phase 7: Verify
1. `rails db:migrate` — passes
2. `rails test` — 0 failures, 0 errors
3. `rails db:seed` — loads venues, artists, follows

---

## 7. File Structure

```
app/
  models/
    core/
      follow.rb
      concerns/core/followable.rb
      concerns/core/social_linkable.rb
    events/
      category.rb
      venue.rb
      artist.rb
  controllers/
    concerns/
      core/
        followable_actions.rb   # Shared follow/unfollow/followers logic
    public/
      application_controller.rb  # Base for public catalog (no auth)
    core/
      follows_controller.rb
      feed_controller.rb
    events/
      categories_controller.rb  # Public catalog (index, show) — uses per-action list/detail serializers
      venues_controller.rb      # Public catalog — includes Core::FollowableActions
      artists_controller.rb     # Public catalog — includes Core::FollowableActions
    admin/
      categories_controller.rb  # Admin CRUD (uses Core::Common)
      venues_controller.rb      # Admin CRUD (uses Core::Common)
      artists_controller.rb     # Admin CRUD (uses Core::Common)
  policies/
    events/
      category_policy.rb
      venue_policy.rb
      artist_policy.rb
    admin/
      category_policy.rb  # Inherits from Events::CategoryPolicy
      venue_policy.rb     # Inherits from Events::VenuePolicy
      artist_policy.rb    # Inherits from Events::ArtistPolicy
    core/
      follow_policy.rb
  serializers/
    events/
      category_serializer.rb              # Admin-side (has_many :audit_logs)
      venue_serializer.rb                 # Admin-side (full detail)
      artist_serializer.rb                # Admin-side (full detail)
      public/
        category_list_serializer.rb       # Public index (id, name, slug)
        category_detail_serializer.rb     # Public show (all public attrs)
        venue_list_serializer.rb          # Public index (lighter payload)
        venue_detail_serializer.rb        # Public show (full public detail)
        artist_list_serializer.rb         # Public index (lighter payload)
        artist_detail_serializer.rb       # Public show (full public detail)
    core/
      follow_serializer.rb
      public/
        user_serializer.rb
config/
  routes.rb
db/
  migrate/
    20260528xxxxxx_create_events_venues.rb
    20260528xxxxxx_create_events_artists.rb
    20260528xxxxxx_create_core_follows.rb
  seeds.rb
test/
  integration/
    events/
      categories_test.rb       # Public catalog (index, show)
      venues_test.rb           # Public catalog (index, show, follow, unfollow, followers)
      artists_test.rb          # Public catalog (index, show, follow, unfollow, followers)
    admin/
      categories_test.rb       # Admin CRUD
      venues_test.rb           # Admin CRUD
      artists_test.rb          # Admin CRUD
    core/
      follows_test.rb
  models/
    events/
      category_test.rb
      venue_test.rb
      artist_test.rb
    core/
      follow_test.rb
docs/
  superpowers/
    specs/
      2026-05-28-venues-artists-and-social-features.md  (this file)
postman/
  Digis API_collection.json
```

---

## 8. Follow Serializer and Policy

### Core::FollowSerializer

```ruby
class Core::FollowSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :id, :followable_type, :followable_id, :followed_at, :created_at

  attribute :follower do |follow|
    Core::Public::UserSerializer.new(follow.follower).as_json
  end

  attribute :followable do |follow|
    { type: follow.followable_type, id: follow.followable_id }
  end
end
```

**Note**: Uses `Core::Public::UserSerializer` to avoid exposing sensitive user data (email, phone) in follow lists.

### Core::FollowPolicy

```ruby
module Core
  class FollowPolicy < Core::ApplicationPolicy
    def create?
      user.present?
    end

    def destroy?
      user.present?
    end

    # Privacy-first: only the current user can view their own following list.
    # Change to `user.present?` to allow any authenticated user to view any
    # user's following list (a valid social-feature design choice).
    def following?
      record == user
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
```

### Core::Public::UserSerializer (for followers endpoints)

```ruby
module Core
  module Public
    class UserSerializer < ActiveModel::Serializer
      attributes :id, :created_at
      # Only exposes id and created_at — no sensitive fields (email, phone, password_digest)
    end
  end
end
```

**Note**: This minimal serializer prevents exposing sensitive user data in public follower lists. It is used by the `Core::FollowableActions` concern in the `followers` action of Venue, Artist, and Organization controllers:

```ruby
# From Core::FollowableActions (defined in §4)
def followers
  record = followable_class.find(params[:id])
  followers = paginated_request? ? apply_pagination(record.followers) : record.followers.limit(25)
  render_success(data: followers, serializer_options: { serializer: Core::Public::UserSerializer })
end
```

---

## 9. Key Design Decisions

1. **Social links as jsonb** — Flexible, queryable with GIN index, no extra tables. Each model validates allowed platform keys.

2. **Follow system as polymorphic** — Single `core_follows` table handles all followable types (Venue, Artist). Easy to add new followable types (e.g., Organizations in separate spec).

3. **Follower count as column** — Denormalized `followers_count` on each followable table for fast reads. Automatically maintained by Rails `counter_cache` on the `Follow` model — no manual increment/decrement needed.

4. **Active Storage for images** — Auto-generate thumbnail (300x300) and medium (800x800) variants. Predefined size classes, not dynamic. Both Venue and Artist use `profile` as the main image attachment name for consistency.

5. **Feed is deferred** — The Follow model can be built now. The feed endpoint depends on the Event model which doesn't exist yet.

6. **Admin-only create/update/destroy** — Venues and Artists are admin-managed reference data.

7. **Followable concern** — Shared behavior for any model that can be followed. Includes `follows`, `followers`, `followed_by?`. Counter maintenance delegated to Rails `counter_cache`.

8. **Social links validation** — Whitelist of allowed platforms. Prevents arbitrary key injection while remaining flexible for new platforms.
9. **Public serializer safety** — Public controllers bypass Pundit (`policy_for_data` returns nil), making serializer declarations the effective contract. Dedicated `Events::Public::CategoryDetailSerializer` strips `has_many :audit_logs` to prevent exposure via `?include=`. See Anchored Summary §1.
10. **`render_success` API** — Does not support `each_serializer:` kwarg; use `serializer_options: { serializer: }` instead. See Anchored Summary §2.
11. **Public serializers are action-specific** — List and detail serializers per resource replace the previous pattern of a single serializer with Pundit VISIBILITY for shape differentiation. Since public endpoints bypass Pundit (`policy_for_data` returns nil), per-action serializer selection is the effective contract. See Anchored Summary §3.
12. **`Core::FollowableActions` concern** — Shared concern eliminates duplicate follow/unfollow/followers logic across Venue, Artist, and Organization controllers. Each controller declares `followable_class` and gets the three actions for free. See Anchored Summary §4.
13. **Following list is privacy-first** — `Core::FollowPolicy#following?` restricts access to current_user only. Change to `user.present?` to make it a public social feature. See Anchored Summary §5.

---

## 10. Anchored Summary

### §1 — Public serializer safety (defense-in-depth)

**Issue**: The live `Events::CategorySerializer` carries `has_many :audit_logs`. Public controllers set `policy_for_data` to nil (bypassing Pundit), making serializer declarations the effective contract. While AMS doesn't auto-include `has_many` associations (they're opt-in via `?include=`), the association was reachable from public endpoints.

**Fix**: Split into dedicated public serializers per action:
- `Events::Public::CategoryListSerializer` — index (id, name, slug only)
- `Events::Public::CategoryDetailSerializer` — show (all public attributes, no associations)

The admin controller continues using the full `Events::CategorySerializer` with `has_many :audit_logs`, which is only included when triggered via VISIBILITY (`include: [:audit_logs]` for admin role).

**Applies to**: `app/serializers/events/category_serializer.rb`, `app/serializers/events/public/category_list_serializer.rb`, `app/serializers/events/public/category_detail_serializer.rb`, `app/controllers/events/categories_controller.rb`

### §2 — `render_success` does not support `each_serializer:` kwarg

**Issue**: Calling `render_success(data: followers, each_serializer: Core::Public::UserSerializer)` fails silently — the `each_serializer:` keyword is captured by `**options` in `render_success` and merged into the response JSON body as a literal key instead of being passed to AMS serialization.

**Fix**: Use `render_success(data: followers, serializer_options: { serializer: Core::Public::UserSerializer })` throughout.

**File**: `app/controllers/concerns/core/json_response.rb:56` — `render_success` method signature.

**Occurrences fixed** (4 in this spec):
- `Events::VenuesController#followers`
- `Events::ArtistsController#followers`
- Follow section code example
- Public::UserSerializer section example

**Related**: The same pattern was fixed in `2026-05-29-organizations-social-features.md` (1 occurrence).

### §3 — Public serializers must be action-specific (no Pundit VISIBILITY on public endpoints)

**Issue**: Public controllers bypass Pundit (`policy_for_data` returns nil at `app/controllers/public/application_controller.rb:86`), so VISIBILITY field tables in policies are never enforced. The original spec defined different index and show field sets in policy VISIBILITY but then used a single serializer for both actions in Venue and Artist controllers. This meant index returned the same full payload as show — the API contract was inconsistent with the spec's own field tables.

**Fix**: Replaced single serializers with dedicated list and detail serializers per resource, explicitly selected per action in the public controllers:

| Resource | List serializer (index) | Detail serializer (show) |
|---|---|---|
| Category | `CategoryListSerializer` — id, name, slug | `CategoryDetailSerializer` — all public attrs |
| Venue | `VenueListSerializer` — no geo/contact/social | `VenueDetailSerializer` — full public detail |
| Artist | `ArtistListSerializer` — thumbnail, no social | `ArtistDetailSerializer` — full URLs, follower count |

**Affected files**: `app/serializers/events/public/venue_list_serializer.rb` (new), `app/serializers/events/public/venue_detail_serializer.rb` (new), `app/serializers/events/public/artist_list_serializer.rb` (new), `app/serializers/events/public/artist_detail_serializer.rb` (new), `app/controllers/events/venues_controller.rb`, `app/controllers/events/artists_controller.rb`

**Cross-reference**: The same pattern was applied in `2026-05-29-organizations-social-features.md` for Organization serializers.

### §4 — Extracted `Core::FollowableActions` concern to eliminate duplication

**Issue**: Follow/unfollow/followers controller logic was duplicated verbatim across three controllers (Venues, Artists, Organizations) with only the model class name and variable name differing. This made changes error-prone and violated DRY.

**Fix**: Extracted `Core::FollowableActions` concern at `app/controllers/concerns/core/followable_actions.rb`. Each public controller includes the concern, declares `followable_class`, and gets follow/unfollow/followers for free. The concern also handles `before_action :authenticate_user` for follow/unfollow.

**Affected files**: `app/controllers/concerns/core/followable_actions.rb` (new), `app/controllers/events/venues_controller.rb`, `app/controllers/events/artists_controller.rb`, `2026-05-29-organizations-social-features.md`

### §5 — `Core::FollowsController#following` now has explicit access policy

**Issue**: The `following` endpoint accepted any `:user_id` and returned that user's following list with only an authentication check. It was underspecified whether this was intentionally public (any authenticated user can see any user's follows) or privacy-restricted.

**Fix**: Explicit guard via Pundit: `authorize user, :following?` in the controller, with `Core::FollowPolicy#following?` returning `record == user` (privacy-first). The comment documents the alternative: change to `user.present?` for a public social feature.

**Affected files**: `app/controllers/core/follows_controller.rb`, `app/policies/core/follow_policy.rb`

### §6 — AMS 0.10.x `attribute` blocks use `instance_eval` (block parameters yield `nil`)

**Issue**: All serializer code used `attribute :foo do |record|` with a block parameter, assuming AMS yields the record. However, AMS 0.10.16 uses `instance_eval(&block)` (not `instance_exec`), so block parameters receive `nil`. Calling `record.profile` on `nil` raises `NoMethodError`.

**Fix**: Access the record via `object` inside the block — no block parameter needed:

```ruby
# Wrong — block param is always nil
attribute :profile_url do |venue|
  venue.profile.attached? ? url_for(venue.profile) : nil
end

# Correct — use `object` instead
attribute :profile_url do
  object.profile.attached? ? url_for(object.profile) : nil
end
```

**File**: `lib/active_model/serializer/field.rb` in AMS 0.10.16 — `Field#value` calls `serializer.instance_eval(&block)`.

**Affected files**: All serializers with `attribute` blocks — `Events::VenueSerializer`, `Events::ArtistSerializer`, `Events::Public::*Serializer`, `Organizations::*Serializer`, `Core::FollowSerializer` (previously used `|follow|` pattern, now uses `object.follower`).

**Prevention**: Always test serializers with the actual controller stack to catch block-parameter bugs. Unit-testing serializers in isolation wouldn't catch this since `instance_eval` with a block that has parameters doesn't raise when `nil` is passed — the error only surfaces when the model method is called on `nil`.
