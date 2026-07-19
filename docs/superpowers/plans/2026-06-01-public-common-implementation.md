# PublicCatalog Common Concern Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `Core::PublicCommon` — a read-only concern that standardizes `index`/`show`, pagination, ordering, optional Ransack search, and per-resource filters for all public catalog endpoints. Migrate 4 controllers to use it.

**Architecture:** Extract the identical hand-rolled index/show pattern from `CategoriesController`, `VenuesController`, `ArtistsController`, and `OrganizationsController` into a single concern. Each controller declares `model_class`, `list_serializer`, `detail_serializer`, and optional hooks (`apply_catalog_filters`, `detail_scope`, `base_scope`, `searchable?`). `Core::FollowableActions` remains separate — the concern is read-only and does not include follow/unfollow/followers.

**Tech Stack:** Rails 8, ActiveModelSerializers, Ransack (optional, per-controller opt-in)

---

### Task 1: Create `Core::PublicCommon` concern

**Files:**
- Create: `app/controllers/concerns/core/public_common.rb`

**Concern design:**

```ruby
module Core
  module PublicCommon
    extend ActiveSupport::Concern

    # Pagination provides: default_per_page, max_per_page, page_no, per_page,
    #   paginated_request?, paginate_offset, apply_pagination, pagination_metadata,
    #   order_by (respects allowed_order_columns), order_direction, apply_ordering
    include Core::Pagination

    included do
      class_attribute :model_class, default: nil
      class_attribute :list_serializer, default: nil
      class_attribute :detail_serializer, default: nil
    end

    def index
      records = build_base_scope
      records = apply_catalog_filters(records)
      records = filter_records(records) if searchable?
      records = apply_ordering(records)

      total_count = records.count if paginated_request?
      records = paginated_request? ? apply_pagination(records) : records.limit(default_per_page)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil

      render_success(
        data: records,
        serializer_options: { serializer: self.class.list_serializer },
        pagination: pagination
      )
    end

    def show
      record = build_detail_scope.find(params[:id])
      render_success(
        data: record,
        serializer_options: { serializer: self.class.detail_serializer }
      )
    end

    private

    def build_base_scope
      base_scope
    end

    def base_scope
      self.class.model_class.all
    end

    def build_detail_scope
      detail_scope
    end

    def detail_scope
      self.class.model_class.all
    end

    # Override in controller to add resource-specific filters (city, genre, etc.)
    def apply_catalog_filters(scope)
      scope
    end

    # Override in controller to return true to enable Ransack q= search
    def searchable?
      false
    end

    # Delegates to Core::Filterable if searchable?
    def filter_records(records)
      return records unless params[:q].present?
      return records unless records.respond_to?(:ransack)

      @q = records.ransack(params[:q])
      @q.result(distinct: true)
    rescue StandardError => error
      Rails.logger.warn("Ransack filter skipped: #{error.class} - #{error.message}")
      records
    end

    # Override in controller to restrict allowed order columns
    def allowed_order_columns
      %w[id created_at]
    end
  end
end
```

- [ ] **Step 1: Create the concern file**

Write the code above to `app/controllers/concerns/core/public_common.rb`.

- [ ] **Step 2: Verify it loads**

Run: `rails runner "puts Core::PublicCommon.instance_methods"` — should print `index`, `show`, etc.

---

### Task 2: Migrate `Events::CategoriesController` (simplest — no follow actions, no filters)

**Files:**
- Modify: `app/controllers/events/categories_controller.rb`
- Test: run existing tests to confirm no regressions

- [ ] **Step 1: Rewrite `Events::CategoriesController`**

Replace the hand-rolled index/show with `Core::PublicCommon`:

```ruby
module Events
  class CategoriesController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Events::Category
    self.list_serializer = Events::Public::CategoryListSerializer
    self.detail_serializer = Events::Public::CategoryDetailSerializer

    private

    def base_scope
      Events::Category.active
    end

    def allowed_order_columns
      %w[id name created_at]
    end
  end
end
```

- [ ] **Step 2: Run existing tests to confirm no regressions**

Run: `rails test test/integration/events/categories_test.rb` — must pass 0 failures.

---

### Task 3: Migrate `Events::ArtistsController` (adds follow actions, profile attachment, genre filter)

**Files:**
- Modify: `app/controllers/events/artists_controller.rb`
- Test: run existing tests to confirm no regressions

- [ ] **Step 1: Rewrite `Events::ArtistsController`**

```ruby
module Events
  class ArtistsController < ::Public::ApplicationController
    include Core::PublicCommon
    include Core::FollowableActions

    self.model_class = Events::Artist
    self.list_serializer = Events::Public::ArtistListSerializer
    self.detail_serializer = Events::Public::ArtistDetailSerializer

    private

    def base_scope
      Events::Artist.active.with_attached_profile
    end

    def detail_scope
      Events::Artist.with_attached_profile
    end

    def apply_catalog_filters(scope)
      scope = scope.by_genre(params[:genre]) if params[:genre].present?
      scope = scope.verified if params[:verified] == "true"
      scope
    end

    def allowed_order_columns
      %w[id name created_at]
    end

    def followable_class
      Events::Artist
    end
  end
end
```

- [ ] **Step 2: Run existing tests to confirm no regressions**

Run: `rails test test/integration/events/artists_test.rb` — must pass 0 failures.

---

### Task 4: Migrate `Events::VenuesController` (follow actions, profile+photos attachments, city/country/verified filters)

**Files:**
- Modify: `app/controllers/events/venues_controller.rb`
- Test: run existing tests to confirm no regressions

- [ ] **Step 1: Rewrite `Events::VenuesController`**

```ruby
module Events
  class VenuesController < ::Public::ApplicationController
    include Core::PublicCommon
    include Core::FollowableActions

    self.model_class = Events::Venue
    self.list_serializer = Events::Public::VenueListSerializer
    self.detail_serializer = Events::Public::VenueDetailSerializer

    private

    def base_scope
      Events::Venue.active.with_attached_profile.with_attached_photos
    end

    def detail_scope
      Events::Venue.with_attached_profile.with_attached_photos
    end

    def apply_catalog_filters(scope)
      scope = scope.by_city(params[:city]) if params[:city].present?
      scope = scope.by_country(params[:country]) if params[:country].present?
      scope = scope.verified if params[:verified] == "true"
      scope
    end

    def allowed_order_columns
      %w[id name city country created_at]
    end

    def followable_class
      Events::Venue
    end
  end
end
```

- [ ] **Step 2: Run existing tests to confirm no regressions**

Run: `rails test test/integration/events/venues_test.rb` — must pass 0 failures.

---

### Task 5: Migrate `Organizations::OrganizationsController` (follow actions, profile attachment, no filters)

**Files:**
- Modify: `app/controllers/organizations/organizations_controller.rb`
- Test: run existing tests to confirm no regressions

- [ ] **Step 1: Rewrite `Organizations::OrganizationsController`**

```ruby
module Organizations
  class OrganizationsController < ::Public::ApplicationController
    include Core::PublicCommon
    include Core::FollowableActions

    self.model_class = Organizations::Organization
    self.list_serializer = Organizations::Public::OrganizationListSerializer
    self.detail_serializer = Organizations::Public::OrganizationDetailSerializer

    private

    def base_scope
      Organizations::Organization.all.with_attached_profile
    end

    def detail_scope
      Organizations::Organization.with_attached_profile
    end

    def allowed_order_columns
      %w[id name slug created_at]
    end

    def followable_class
      Organizations::Organization
    end
  end
end
```

- [ ] **Step 2: Run existing tests to confirm no regressions**

Run: `rails test test/integration/organizations/organizations_test.rb` — must pass 0 failures.

---

### Task 6: Run full test suite and verify

- [ ] **Run full test suite**

Run: `rails test` — must pass 700 tests, 0 failures.

---

### Task 7: Commit

- [ ] **Stage and commit**

```bash
git add app/controllers/concerns/core/public_common.rb app/controllers/events/categories_controller.rb app/controllers/events/artists_controller.rb app/controllers/events/venues_controller.rb app/controllers/organizations/organizations_controller.rb
git commit -m "feat(public): extract Core::PublicCommon concern for public catalog endpoints

- Create Core::PublicCommon concern standardizing index/show, pagination,
  ordering, optional Ransack search, and per-resource filters
- Migrate Events::CategoriesController — simplest (no follow actions)
- Migrate Events::ArtistsController — adds genre/verified filters
- Migrate Events::VenuesController — adds city/country/verified filters
- Migrate Organizations::OrganizationsController — no resource filters
- Core::FollowableActions remains separate (not absorbed by PublicCommon)
"
```
