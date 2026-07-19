# Spec: Organizations Follow & Social Features

**Date**: 2026-05-29
**Status**: Draft
**Author**: opencode
**Depends On**: `2026-05-28-venues-artists-and-social-features.md`

---

## Overview

This spec extends the Organizations module with follow system and social features. It builds on the Core::Follow and Core::SocialLinkable infrastructure defined in the Venues/Artists spec.

**Note**: Organizations can follow/be-followed like Venues and Artists. This spec adds Organization to the polymorphic follow system and adds social links/profile to the Organization model.

---

## 1. Model Updates

### Organization Model

Add `Core::Followable`, `Core::SocialLinkable`, and profile attachment:

```ruby
module Organizations
  class Organization < Organizations::ApplicationRecord
    include Core::AuditableModel
    include Core::Slugable
    include Core::Followable
    include Core::SocialLinkable

    slugable source: :name, target: :slug

    has_one_attached :profile   # Organization logo/profile image (optional)
    has_many :memberships, dependent: :destroy
    has_one :owner_membership, -> { where(role: :owner) }, class_name: "Organizations::Membership"
    has_one :owner, through: :owner_membership, source: :user

    validates :name, presence: true, uniqueness: true
    validates :slug, presence: true, uniqueness: true
    validates :followers_count, numericality: { greater_than_or_equal_to: 0 }

    def self.ransackable_attributes(_auth_object = nil)
      %w[name slug description created_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[memberships]
    end
  end
end
```

### Migration

Add `social_links`, `followers_count`, and `profile` attachment:

```ruby
class AddSocialFieldsToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations_organizations, :social_links, :jsonb, default: {}
    add_column :organizations_organizations, :followers_count, :integer, default: 0, null: false
  end
end
```

---

## 2. Policy Updates

Keep existing owner-only behavior for show/update/destroy, add follow methods:

```ruby
module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true  # Public — anyone can view organization profile (for following)
    end

    def create?
      true  # Open/self-serve — anyone can create an organization
    end

    def update?
      record.owner == user || user&.super_admin?
    end

    def destroy?
      record.owner == user || user&.super_admin?
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
        default: { fields: %i[id name slug description created_at], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name slug description profile_url social_links followers_count created_at], include: [] },
        admin: { include: [] }
      }
    }
    # Note: VISIBILITY only governs serialized output (response attributes).
    # Write contract (permitted params) is defined in controller's #model_params.

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
```

---

## 3. Serializer Updates

Add social_links, follower_count, and profile_url.

**Owner-side serializer** (used by `OwnerOrganizationsController` and also serves as the default AMS serializer for the model):

```ruby
# Shared serializer — used by owner controllers. Public endpoints use a
# dedicated public serializer that excludes sensitive associations (see below).
class Organizations::OrganizationSerializer < ActiveModel::Serializer
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
```

**Public list serializer** (public catalog index — lighter payload):

```ruby
class Organizations::Public::OrganizationListSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer
  include Rails.application.routes.url_helpers

  attributes :id, :name, :slug, :description, :created_at

  attribute :profile_url do |organization|
    organization.profile.attached? ? url_for(organization.profile.variant(resize_to_fill: [300, 300])) : nil
  end
end
```

**Public detail serializer** (public catalog show — full public detail with social links and follower count):

```ruby
class Organizations::Public::OrganizationDetailSerializer < ActiveModel::Serializer
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
```

**Design note**: Public controllers bypass Pundit (`policy_for_data` returns nil), so serializer declarations are the effective contract for public endpoints. Action-specific serializers (list vs detail) ensure index and show return different payloads without relying on Pundit VISIBILITY (which is bypassed). Dedicated public serializers also prevent associations like `memberships` (which chain to `Core::UserAuthSerializer`) from being inadvertently reachable via `?include=`. Only declare associations on public serializers that are explicitly safe for unauthenticated exposure. See Anchored Summary §3.

---

## 4. Controller Updates

### Public Controller

```ruby
module Organizations
  class OrganizationsController < Public::ApplicationController
    include Core::FollowableActions

    # Public: index, show — uses per-action public serializers
    # (list vs detail) for different response shapes.
    # See Anchored Summary §3.
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

### Owner CRUD Controller

```ruby
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

## 5. Routes

**Note**: The existing `organizations/organizations` route block must be **replaced** (not appended) to avoid duplicate route conflicts.

```ruby
namespace :organizations do
  resources :organizations, only: %i[index show] do
    member do
      post :follow
      post :unfollow
      get :followers
    end
  end

  # Owner-only write actions — explicit singleton routes to avoid duplicating
  # `resources :organizations` (which would create unreachable index/show entries
  # and ambiguous route helpers). See Anchored Summary §1.
  # Named helpers are: organizations_owner_organizations_path (create),
  # organizations_owner_organization_path(id) (update/destroy).
  post   "organizations",       to: "owner_organizations#create",   as: :owner_organizations
  patch  "organizations/:id",   to: "owner_organizations#update",   as: :owner_organization
  put    "organizations/:id",   to: "owner_organizations#update"
  delete "organizations/:id",   to: "owner_organizations#destroy"

  # Memberships — nested under the owner-managed organization path
  # Named helper: organizations_organization_memberships_path(organization_id)
  resources :memberships, except: %i[new edit], controller: "memberships",
            path: "organizations/:organization_id/memberships",
            as: :organization_memberships
end
```

This routes:
- Public actions (index, show, follow, unfollow, followers) → `Organizations::OrganizationsController`
- Owner CRUD actions (create, update, destroy, memberships) → `Organizations::OwnerOrganizationsController`

Route helpers (all prefixed with `organizations_` from the namespace):
- `organizations_organizations_path` / `organizations_organization_path(id)` → public read actions
- `organizations_owner_organizations_path` / `organizations_owner_organization_path(id)` → owner write actions (create, update, destroy)
- `organizations_organization_memberships_path(org_id)` / `organizations_organization_membership_path(org_id, id)` → owner membership management

---

## 6. Implementation Order

### Phase 1: Organization Model Updates
1. Add `social_links` jsonb column to `organizations_organizations`
2. Add `followers_count` integer column to `organizations_organizations`
3. Add `Core::SocialLinkable` concern (from Venues/Artists spec)
4. Include `Core::Followable` and `Core::SocialLinkable` in Organization model
5. Add `has_one_attached :profile` to Organization model
6. Write model tests (validations, social links)

### Phase 2: Organization Policy & Serializers
1. Update `Organizations::OrganizationPolicy` — add follow methods
2. Update `Organizations::OrganizationSerializer` — add social_links, follower_count, profile_url
3. Create `Organizations::Public::OrganizationListSerializer` — public index (lighter payload, no social_links/follower_count)
4. Create `Organizations::Public::OrganizationDetailSerializer` — public show (full detail)
5. Write policy tests

### Phase 3: Organization Controllers
1. Create `Public::ApplicationController` (if not already created in Spec 1)
2. Create `Core::FollowableActions` concern (if not already created in Spec 1)
3. Update `Organizations::OrganizationsController` — inherit from Public::ApplicationController, include Core::FollowableActions
4. Create `Organizations::OwnerOrganizationsController` — CRUD with owner-based auth (uses Core::Common)
5. Update `config/routes.rb` — split public and owner routes
6. Write integration tests:
   - Public: index, show, followers without authentication
   - Follow/unfollow: authenticated actions
   - Owner: CRUD with owner-based auth

---

## 7. File Structure

```
app/
  models/
    organizations/
      organization.rb  (updated: add Followable, SocialLinkable, profile)
  controllers/
    concerns/
      core/
        followable_actions.rb         (shared from venues spec)
    organizations/
      organizations_controller.rb       (updated: public catalog, includes Core::FollowableActions)
      owner_organizations_controller.rb (new: owner CRUD, uses Core::Common)
  policies/
    organizations/
      organization_policy.rb            (updated: add follow methods)
  serializers/
    organizations/
      organization_serializer.rb        (updated: add social fields)
      public/
        organization_list_serializer.rb   (new: public index — lighter payload)
        organization_detail_serializer.rb (new: public show — full detail)
```

---

## 8. Key Design Decisions

1. **Public show** — Anyone can view organization profile (for following)
2. **Owner-only update/destroy** — Only owner or super_admin can modify/delete
3. **Public index** — Anyone can browse organizations
4. **Consumer follow** — follow/unfollow/followers return `true` (no RBAC)
5. **Profile attachment** — Uses Active Storage like Venue/Artist
6. **Social links** — Uses Core::SocialLinkable (same as Venue/Artist)
7. **Two-controller split** — Public::ApplicationController for catalog, Organizations::ApplicationController for owner CRUD (avoids authorization conflicts)
8. **Public serializer safety** — Public controllers bypass Pundit visibility (`policy_for_data` returns nil), so serializer declarations become the effective contract for public endpoints. Dedicated public serializers (`OrganizationListSerializer` / `OrganizationDetailSerializer`) strip associations like `has_many :memberships` that chain to `Core::UserAuthSerializer`. See Anchored Summary §2.
9. **Explicit owner write routes** — Avoids duplicate `resources :organizations` blocks which cause route helper conflicts and maintenance confusion. See Anchored Summary §1.
10. **Action-specific public serializers** — Index uses `OrganizationListSerializer` (name, slug, description, created_at), show uses `OrganizationDetailSerializer` (adds social_links, follower_count, full profile_url). See Anchored Summary §3.
11. **Shared follow actions via concern** — `OrganizationsController` includes `Core::FollowableActions` from the Venues/Artists spec, eliminating duplicated follow/unfollow/followers logic. See venues spec Anchored Summary §4.

### Breaking Changes from Existing Policy

This spec intentionally changes the existing OrganizationPolicy behavior:

| Action | Existing Behavior | New Behavior | Reason |
|--------|------------------|--------------|--------|
| `show?` | Owner-only | Public | Enable following |
| `Scope#resolve` | Owner-only | All organizations | Public index |
| `name` validation | `presence: true` | `presence: true, uniqueness: true` | Prevent duplicate org names |

These changes are intentional to support the public catalog and following features.

---

## 9. Notes

- This spec depends on `Core::Follow`, `Core::Followable`, `Core::SocialLinkable`, and `Core::FollowableActions` from the Venues/Artists spec
- The `Public::ApplicationController` should already exist from the Venues/Artists spec
- The follow system uses the same polymorphic `core_follows` table
- `OrganizationsController` includes `Core::FollowableActions` (defined in venues spec) instead of hand-rolling follow/unfollow/followers — see venues spec §4

---

## 10. Anchored Summary

### §1 — Route duplication (avoid duplicate `resources :organizations`)

**Issue**: The initial spec used two `resources :organizations` blocks in the same namespace — one with `only: %i[index show]` for public reads, another with `except: %i[new edit]` for owner CRUD. This works via Rails top-down route matching but creates:
- Route helper conflicts (both blocks generate helpers with the same names)
- The second block's `except:` silently generates unreachable `index`/`show` routes
- Adding actions to either block risks silent route conflicts

**Fix**: Single `resources` block for public read actions + explicit singleton routes (`post`, `patch`, `delete`) for owner write actions. See [§5 — Routes](#5-routes).

**Applies to**: `config/routes.rb`

**Applies also to**: The Venues/Artists spec avoids this issue entirely — public and admin routes are in different namespaces (`events` vs `admin`). Only the Organizations module has this namespace collision because both controllers share the same `organizations/organizations` path prefix.

### §2 — Public serializer safety (defense-in-depth)

**Issue**: Public controllers set `policy_for_data` to nil (bypassing Pundit), making serializer declarations the effective contract. The shared `OrganizationSerializer` carried `has_many :memberships`, which chains through `Organizations::MembershipSerializer` → `belongs_to :user, serializer: Core::UserAuthSerializer`, exposing `email`, `phone`, `permissions`, and `roles`. While AMS doesn't auto-include `has_many` associations (they're opt-in via `?include=`), this created a reachable surface for data leakage.

**Fix**: Split into public serializers per action:
- `Organizations::OrganizationSerializer` — shared/full serializer with `has_many :memberships` (used by owner controller)
- `Organizations::Public::OrganizationListSerializer` — public index (name, slug, description, created_at, thumbnail profile_url)
- `Organizations::Public::OrganizationDetailSerializer` — public show (full profile_url, social_links, follower_count)

The list serializer omits `has_many :memberships` entirely, closing the `UserAuthSerializer` chain from public endpoints.

**Applies to**: `app/serializers/organizations/organization_serializer.rb`, `app/serializers/organizations/public/organization_list_serializer.rb` (new), `app/serializers/organizations/public/organization_detail_serializer.rb` (new), `app/controllers/organizations/organizations_controller.rb`

### §3 — Public serializers must be action-specific (no Pundit VISIBILITY on public endpoints)

**Issue**: Same pattern as the Venues/Artists spec — the original spec used a single public serializer for both index and show, while VISIBILITY defined different field sets. Since public endpoints bypass Pundit (`policy_for_data` returns nil), VISIBILITY is never enforced, making index and show return identical payloads.

**Fix**: Split into `OrganizationListSerializer` (index — lighter) and `OrganizationDetailSerializer` (show — full detail with social_links, follower_count). The public controller explicitly selects the correct serializer per action.

**Applies to**: `app/serializers/organizations/public/organization_list_serializer.rb` (new), `app/serializers/organizations/public/organization_detail_serializer.rb` (new), `app/controllers/organizations/organizations_controller.rb`

**Cross-reference**: Applied in both `2026-05-28-venues-artists-and-social-features.md` and `2026-05-29-organizations-social-features.md`.

### §4 — `render_success` does not support `each_serializer:` kwarg

**Issue**: Calling `render_success(data: followers, each_serializer: Core::Public::UserSerializer)` fails silently — the `each_serializer:` keyword is captured by `**options` in `render_success` (`app/controllers/concerns/core/json_response.rb:56`) and merged into the response JSON body as a literal key (`response.merge!(options)` on line 69), instead of being passed to the AMS serialization call.

**Fix**: Use `render_success(data: followers, serializer_options: { serializer: Core::Public::UserSerializer })`. The `serialize_relation` method reads `options[:serializer]` and uses it as the explicit serializer for all records in the collection.

**Applies to**: All `render_success` calls that pass `each_serializer:` — in both the Venues/Artists spec and this spec.

**Cross-reference**: Fixed in both `2026-05-28-venues-artists-and-social-features.md` (4 occurrences) and `2026-05-29-organizations-social-features.md` (1 occurrence).
