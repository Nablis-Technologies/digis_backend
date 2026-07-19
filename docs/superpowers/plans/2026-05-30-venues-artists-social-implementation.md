# Venues, Artists & Social Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement public catalog endpoints, admin CRUD, and follow system for Venues, Artists, and Categories, plus Organization social features.

**Architecture:** Public controllers inherit from `Public::ApplicationController` (no Pundit, optional auth). Admin controllers inherit from `Admin::ApplicationController` (full Pundit). Follow actions shared via `Core::FollowableActions` concern. Public serializers are split into list/detail per resource.

**Tech Stack:** Rails 8.1, Active Model Serializers, Pundit, Active Storage, PostgreSQL

---

### Task 1: Public::ApplicationController and Model Concerns

**Files:**
- Create: `app/controllers/public/application_controller.rb`
- Create: `app/models/concerns/core/followable.rb`
- Create: `app/models/concerns/core/social_linkable.rb`
- Create: `app/controllers/concerns/core/followable_actions.rb`
- Create: `app/policies/core/follow_policy.rb`
- Create: `app/controllers/core/follows_controller.rb`
- Create: `app/serializers/core/public/user_serializer.rb`
- Create: `app/serializers/core/follow_serializer.rb`

- [ ] **Step 1: Create Public::ApplicationController**

```ruby
# app/controllers/public/application_controller.rb
module Public
  class ApplicationController < ::ApplicationController
    include Core::JsonResponse
    include Core::Authenticatable
    include Core::Pagination

    rescue_from ActiveRecord::RecordNotFound do |error|
      model_name = error.model&.constantize&.model_name&.human&.downcase || "resource"
      render_error(I18n.t(:"errors.not_found", model: model_name), status: :not_found)
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      render_error(errors: error.record.errors, status: :unprocessable_entity)
    end

    private

    def policy_for_data(data)
      nil
    end
  end
end
```

- [ ] **Step 2: Create Core::Followable concern**

```ruby
# app/models/concerns/core/followable.rb
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

- [ ] **Step 3: Create Core::SocialLinkable concern**

```ruby
# app/models/concerns/core/social_linkable.rb
module Core
  module SocialLinkable
    extend ActiveSupport::Concern

    VALID_SOCIAL_PLATFORMS = %w[
      instagram twitter tiktok youtube facebook website
      spotify soundcloud apple_music telegram whatsapp discord
    ].freeze

    MAX_SOCIAL_LINKS = 10
    MAX_URL_LENGTH = 2048

    included do
      before_validation :normalize_social_links
      validate :validate_social_links
    end

    private

    def normalize_social_links
      return if social_links.blank?
      self.social_links = social_links.transform_keys(&:to_s).transform_values { |v| v.to_s.strip }
    end

    def validate_social_links
      return if social_links.blank?

      if social_links.size > MAX_SOCIAL_LINKS
        errors.add(:social_links, "exceeds maximum of #{MAX_SOCIAL_LINKS} platforms")
        return
      end

      invalid_keys = social_links.keys - VALID_SOCIAL_PLATFORMS
      if invalid_keys.any?
        errors.add(:social_links, "contains unsupported platforms: #{invalid_keys.join(', ')}")
        return
      end

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

- [ ] **Step 4: Create Core::FollowableActions concern**

```ruby
# app/controllers/concerns/core/followable_actions.rb
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

- [ ] **Step 5: Create Core::FollowPolicy**

```ruby
# app/policies/core/follow_policy.rb
module Core
  class FollowPolicy < Core::ApplicationPolicy
    def create?
      user.present?
    end

    def destroy?
      user.present?
    end

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

- [ ] **Step 6: Create Core::FollowsController**

```ruby
# app/controllers/core/follows_controller.rb
module Core
  class FollowsController < Core::ApplicationController
    skip_authorization only: [:following]

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

- [ ] **Step 7: Create Core::Public::UserSerializer**

```ruby
# app/serializers/core/public/user_serializer.rb
module Core
  module Public
    class UserSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      attributes :id, :created_at
    end
  end
end
```

- [ ] **Step 8: Create Core::FollowSerializer**

```ruby
# app/serializers/core/follow_serializer.rb
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

---

### Task 2: Create Public Category Serializers & Refactor Category Controller

**Files:**
- Create: `app/serializers/events/public/category_list_serializer.rb`
- Create: `app/serializers/events/public/category_detail_serializer.rb`
- Modify: `app/controllers/events/categories_controller.rb`
- Create: `app/controllers/admin/categories_controller.rb`
- Create: `app/policies/admin/category_policy.rb`
- Modify: `app/policies/events/category_policy.rb`
- Modify: `config/routes.rb`

- [ ] **Step 1: Create Events::Public::CategoryListSerializer**

```ruby
# app/serializers/events/public/category_list_serializer.rb
class Events::Public::CategoryListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :slug
end
```

- [ ] **Step 2: Create Events::Public::CategoryDetailSerializer**

```ruby
# app/serializers/events/public/category_detail_serializer.rb
class Events::Public::CategoryDetailSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
end
```

- [ ] **Step 3: Rewrite Events::CategoriesController to public-only**

```ruby
# app/controllers/events/categories_controller.rb
module Events
  class CategoriesController < Public::ApplicationController
    def index
      categories = Events::Category.active
      categories = paginated_request? ? apply_pagination(categories) : categories.limit(25)
      render_success(data: categories, serializer_options: { serializer: Events::Public::CategoryListSerializer })
    end

    def show
      category = Events::Category.find(params[:id])
      render_success(data: category, serializer_options: { serializer: Events::Public::CategoryDetailSerializer })
    end
  end
end
```

- [ ] **Step 4: Create Admin::CategoriesController**

```ruby
# app/controllers/admin/categories_controller.rb
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

- [ ] **Step 5: Create Admin::CategoryPolicy**

```ruby
# app/policies/admin/category_policy.rb
module Admin
  class CategoryPolicy < Events::CategoryPolicy
  end
end
```

- [ ] **Step 6: Update Events::CategoryPolicy** — add index VISIBILITY and update destroy? to use `allowed?`

```ruby
# app/policies/events/category_policy.rb
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

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")
        scope.active
      end
    end
  end
end
```

- [ ] **Step 7: Update routes.rb** — split categories into public + admin, add venues/artists

```ruby
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  scope module: :core do
    post "auth/login", to: "auth#login"
    post "auth/signup", to: "auth#signup"
    post "auth/refresh", to: "auth#refresh"
    post "auth/logout", to: "auth#logout"
    get "auth/me", to: "auth#me"
  end

  namespace :events do
    resources :categories, only: %i[index show]
    resources :venues, only: %i[index show] do
      member do
        post :follow
        post :unfollow
        get :followers
      end
    end
    resources :artists, only: %i[index show] do
      member do
        post :follow
        post :unfollow
        get :followers
      end
    end
  end

  namespace :admin do
    resources :users, except: %i[new edit] do
      member do
        post :deactivate
        post :reactivate
      end
      resources :roles, only: %i[index create destroy], controller: "user_roles", param: :role_id
    end
    resources :roles, except: %i[new edit]
    resources :permissions, except: %i[new edit]
    resources :categories, except: %i[new edit]
    resources :venues, except: %i[new edit]
    resources :artists, except: %i[new edit]
  end

  namespace :organizations do
    resources :organizations, only: %i[index show] do
      member do
        post :follow
        post :unfollow
        get :followers
      end
    end
    post   "organizations",       to: "owner_organizations#create",   as: :owner_organizations
    patch  "organizations/:id",   to: "owner_organizations#update",   as: :owner_organization
    put    "organizations/:id",   to: "owner_organizations#update"
    delete "organizations/:id",   to: "owner_organizations#destroy"
    resources :memberships, except: %i[new edit], controller: "memberships",
              path: "organizations/:organization_id/memberships",
              as: :organization_memberships
  end

  scope module: :core do
    get "users/:user_id/following", to: "follows#following"
    get "feed", to: "feed#index"
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
```

---

### Task 3: Create Venue Model, Migration, Serializers, Controllers, Policy

**Files:**
- Create: `db/migrate/20260530000001_create_events_venues.rb`
- Create: `app/models/events/venue.rb`
- Create: `app/serializers/events/venue_serializer.rb`
- Create: `app/serializers/events/public/venue_list_serializer.rb`
- Create: `app/serializers/events/public/venue_detail_serializer.rb`
- Create: `app/controllers/events/venues_controller.rb`
- Create: `app/controllers/admin/venues_controller.rb`
- Create: `app/policies/events/venue_policy.rb`
- Create: `app/policies/admin/venue_policy.rb`

- [ ] **Step 1: Create Venue migration**

```ruby
# db/migrate/20260530000001_create_events_venues.rb
class CreateEventsVenues < ActiveRecord::Migration[8.1]
  def change
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
      t.jsonb    :amenities,      default: []
      t.jsonb    :social_links,   default: {}
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
  end
end
```

- [ ] **Step 2: Create Venue model**

```ruby
# app/models/events/venue.rb
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

- [ ] **Step 3: Create Venue admin serializer**

```ruby
# app/serializers/events/venue_serializer.rb
class Events::VenueSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :address, :city, :country,
             :latitude, :longitude, :capacity, :amenities, :social_links,
             :contact_phone, :contact_email, :website_url,
             :verified, :active, :created_at, :updated_at

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

- [ ] **Step 4: Create Venue public list serializer**

```ruby
# app/serializers/events/public/venue_list_serializer.rb
class Events::Public::VenueListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :address, :city, :country,
             :capacity, :verified, :active

  attribute :profile_urls do |venue|
    {
      thumbnail: venue.profile.attached? ? url_for(venue.profile.variant(resize_to_fill: [300, 300])) : nil,
      medium: venue.profile.attached? ? url_for(venue.profile.variant(resize_to_fill: [800, 800])) : nil
    }
  end
end
```

- [ ] **Step 5: Create Venue public detail serializer**

```ruby
# app/serializers/events/public/venue_detail_serializer.rb
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

- [ ] **Step 6: Create Venues public controller**

```ruby
# app/controllers/events/venues_controller.rb
module Events
  class VenuesController < Public::ApplicationController
    include Core::FollowableActions

    def index
      venues = Events::Venue.active
      venues = paginated_request? ? apply_pagination(venues) : venues.limit(25)
      render_success(data: venues, serializer_options: { serializer: Events::Public::VenueListSerializer })
    end

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

- [ ] **Step 7: Create Venues admin controller**

```ruby
# app/controllers/admin/venues_controller.rb
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

- [ ] **Step 8: Create Venue policy**

```ruby
# app/policies/events/venue_policy.rb
module Events
  class VenuePolicy < Core::ApplicationPolicy
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
      true
    end

    def unfollow?
      true
    end

    def followers?
      true
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

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.active
      end
    end
  end
end
```

- [ ] **Step 9: Create Admin::VenuePolicy**

```ruby
# app/policies/admin/venue_policy.rb
module Admin
  class VenuePolicy < Events::VenuePolicy
  end
end
```

---

### Task 4: Create Artist Model, Migration, Serializers, Controllers, Policy

**Files:**
- Create: `db/migrate/20260530000002_create_events_artists.rb`
- Create: `app/models/events/artist.rb`
- Create: `app/serializers/events/artist_serializer.rb`
- Create: `app/serializers/events/public/artist_list_serializer.rb`
- Create: `app/serializers/events/public/artist_detail_serializer.rb`
- Create: `app/controllers/events/artists_controller.rb`
- Create: `app/controllers/admin/artists_controller.rb`
- Create: `app/policies/events/artist_policy.rb`
- Create: `app/policies/admin/artist_policy.rb`

- [ ] **Step 1: Create Artist migration**

```ruby
# db/migrate/20260530000002_create_events_artists.rb
class CreateEventsArtists < ActiveRecord::Migration[8.1]
  def change
    create_table :events_artists, id: :uuid do |t|
      t.string   :name,           null: false
      t.string   :slug,           null: false
      t.text     :description
      t.string   :image_url
      t.jsonb    :genres,         default: []
      t.jsonb    :social_links,   default: {}
      t.boolean  :verified,       default: false
      t.boolean  :active,         default: true
      t.integer  :followers_count, default: 0, null: false
      t.jsonb    :metadata,       default: {}
      t.timestamps
    end

    add_index :events_artists, :slug, unique: true
    add_index :events_artists, :verified
    add_index :events_artists, :active
    add_index :events_artists, :genres, using: :gin
  end
end
```

- [ ] **Step 2: Create Artist model**

```ruby
# app/models/events/artist.rb
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

- [ ] **Step 3: Create Artist admin serializer**

```ruby
# app/serializers/events/artist_serializer.rb
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

- [ ] **Step 4: Create Artist public list serializer**

```ruby
# app/serializers/events/public/artist_list_serializer.rb
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

- [ ] **Step 5: Create Artist public detail serializer**

```ruby
# app/serializers/events/public/artist_detail_serializer.rb
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

- [ ] **Step 6: Create Artists public controller**

```ruby
# app/controllers/events/artists_controller.rb
module Events
  class ArtistsController < Public::ApplicationController
    include Core::FollowableActions

    def index
      artists = Events::Artist.active
      artists = paginated_request? ? apply_pagination(artists) : artists.limit(25)
      render_success(data: artists, serializer_options: { serializer: Events::Public::ArtistListSerializer })
    end

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

- [ ] **Step 7: Create Artists admin controller**

```ruby
# app/controllers/admin/artists_controller.rb
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

- [ ] **Step 8: Create Artist policy**

```ruby
# app/policies/events/artist_policy.rb
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
      true
    end

    def unfollow?
      true
    end

    def followers?
      true
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

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.active
      end
    end
  end
end
```

- [ ] **Step 9: Create Admin::ArtistPolicy**

```ruby
# app/policies/admin/artist_policy.rb
module Admin
  class ArtistPolicy < Events::ArtistPolicy
  end
end
```

---

### Task 5: Create Follow Model, Migration, and Update User Model

**Files:**
- Create: `db/migrate/20260530000003_create_core_follows.rb`
- Create: `app/models/core/follow.rb`
- Modify: `app/models/core/user.rb`

- [ ] **Step 1: Create Follow migration**

```ruby
# db/migrate/20260530000003_create_core_follows.rb
class CreateCoreFollows < ActiveRecord::Migration[8.1]
  def change
    create_table :core_follows, id: :uuid do |t|
      t.references :follower, null: false, foreign_key: { to_table: :core_users }, type: :uuid
      t.uuid     :followable_id,   null: false
      t.string   :followable_type, null: false
      t.datetime :followed_at,     null: false
      t.timestamps
    end

    add_index :core_follows, [:follower_id, :followable_id, :followable_type], unique: true, name: "index_follows_uniqueness"
    add_index :core_follows, [:followable_id, :followable_type], name: "index_follows_followable"
  end
end
```

- [ ] **Step 2: Create Follow model**

```ruby
# app/models/core/follow.rb
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

- [ ] **Step 3: Add `active_follows` to Core::User**

Add after line 14 (after roles through user_roles):

```ruby
    has_many :active_follows,
             class_name: "Core::Follow",
             foreign_key: :follower_id,
             dependent: :destroy
```

---

### Task 6: Update Organization for Social Features

**Files:**
- Create: `db/migrate/20260530000004_add_social_fields_to_organizations.rb`
- Modify: `app/models/organizations/organization.rb`
- Modify: `app/policies/organizations/organization_policy.rb`
- Modify: `app/serializers/organizations/organization_serializer.rb`
- Create: `app/serializers/organizations/public/organization_list_serializer.rb`
- Create: `app/serializers/organizations/public/organization_detail_serializer.rb`
- Modify: `app/controllers/organizations/organizations_controller.rb`
- Create: `app/controllers/organizations/owner_organizations_controller.rb`

- [ ] **Step 1: Create Organization migration**

```ruby
# db/migrate/20260530000004_add_social_fields_to_organizations.rb
class AddSocialFieldsToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations_organizations, :social_links, :jsonb, default: {}
    add_column :organizations_organizations, :followers_count, :integer, default: 0, null: false
  end
end
```

- [ ] **Step 2: Update Organization model**

Add `include Core::Followable`, `include Core::SocialLinkable`, `has_one_attached :profile`, and `uniqueness: true` on name validation:

```ruby
# app/models/organizations/organization.rb
module Organizations
  class Organization < Organizations::ApplicationRecord
    self.table_name = "organizations_organizations"

    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached :profile
    has_many :memberships,
             class_name: "Organizations::Membership",
             dependent: :destroy
    has_one :owner_membership,
            -> { where(role: :owner) },
            class_name: "Organizations::Membership"

    validates :name, presence: true, uniqueness: true
    validates :slug, presence: true, uniqueness: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

    def owner
      owner_membership&.user
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[name slug description created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[memberships]
    end
  end
end
```

- [ ] **Step 3: Update OrganizationPolicy**

```ruby
# app/policies/organizations/organization_policy.rb
module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    def create?
      true
    end

    def update?
      record.owner == user || user&.super_admin?
    end

    def destroy?
      record.owner == user || user&.super_admin?
    end

    def follow?
      true
    end

    def unfollow?
      true
    end

    def followers?
      true
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description created_at], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name slug description profile_url social_links followers_count created_at], include: [] },
        admin: { include: [] }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
```

- [ ] **Step 4: Update OrganizationSerializer**

```ruby
# app/serializers/organizations/organization_serializer.rb
module Organizations
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    attributes :id, :name, :slug, :description, :social_links, :created_at

    has_many :memberships, serializer: Organizations::MembershipSerializer

    attribute :profile_url do |organization|
      organization.profile.attached? ? url_for(organization.profile) : nil
    end

    attribute :follower_count do |organization|
      organization.followers_count
    end
  end
end
```

- [ ] **Step 5: Create Organization public list serializer**

```ruby
# app/serializers/organizations/public/organization_list_serializer.rb
module Organizations
  module Public
    class OrganizationListSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      include Rails.application.routes.url_helpers

      attributes :id, :name, :slug, :description, :created_at

      attribute :profile_url do |organization|
        organization.profile.attached? ? url_for(organization.profile.variant(resize_to_fill: [300, 300])) : nil
      end
    end
  end
end
```

- [ ] **Step 6: Create Organization public detail serializer**

```ruby
# app/serializers/organizations/public/organization_detail_serializer.rb
module Organizations
  module Public
    class OrganizationDetailSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer
      include Rails.application.routes.url_helpers

      attributes :id, :name, :slug, :description, :social_links, :created_at

      attribute :profile_url do |organization|
        organization.profile.attached? ? url_for(organization.profile) : nil
      end

      attribute :follower_count do |organization|
        organization.followers_count
      end
    end
  end
end
```

- [ ] **Step 7: Rewrite OrganizationsController to public-only**

```ruby
# app/controllers/organizations/organizations_controller.rb
module Organizations
  class OrganizationsController < Public::ApplicationController
    include Core::FollowableActions

    def index
      organizations = Organizations::Organization.all
      organizations = paginated_request? ? apply_pagination(organizations) : organizations.limit(25)
      render_success(data: organizations, serializer_options: { serializer: Organizations::Public::OrganizationListSerializer })
    end

    def show
      organization = Organizations::Organization.find(params[:id])
      render_success(data: organization, serializer_options: { serializer: Organizations::Public::OrganizationDetailSerializer })
    end

    private

    def followable_class
      Organizations::Organization
    end
  end
end
```

- [ ] **Step 8: Create OwnerOrganizationsController**

```ruby
# app/controllers/organizations/owner_organizations_controller.rb
module Organizations
  class OwnerOrganizationsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Organization

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:organization).permit(:name, :description, :profile, social_links: {})
    end

    def allowed_order_columns
      %w[id name slug created_at updated_at]
    end

    def after_create_hook(organization)
      organization.memberships.create!(user: current_user, role: :owner)
    end

    def serializer_profile
      {
        create: { fields: %i[id name slug description created_at] },
        update: { fields: %i[id name slug description created_at] }
      }
    end
  end
end
```

---

### Task 7: Migrate and Verify

- [ ] **Step 1: Run migrations**

Run: `rails db:migrate`
Expected: All migrations pass, schema updated with events_venues, events_artists, core_follows tables

- [ ] **Step 2: Verify routes**

Run: `rails routes`
Expected: All new routes present — public events categories/venues/artists, admin CRUD routes, public/owner organization routes, following route
