# Public Catalog Common Concern Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `Core::PublicCommon` concern to eliminate hand-rolled index/show duplication across 4 public catalog controllers and standardize pagination, ordering, optional search, and per-resource filters.

**Architecture:** A controller concern that provides `index` and `show` via a declarative config (`model_class`, `list_serializer`, `detail_serializer`) with override hooks for `base_scope`, `detail_scope`, `apply_catalog_filters`, and `searchable?`. Reuses existing `Core::Pagination` (ordering already built in) and `Core::Filterable` for Ransack search.

**Tech Stack:** Rails 8, ActiveSupport::Concern, ActiveModelSerializers, Ransack

**Spec:** `docs/superpowers/specs/2026-06-01-public-catalog-common-design.md`

---

## File Structure

| File | Change |
|------|--------|
| `app/controllers/concerns/core/public_common.rb` | **Create** — new concern |
| `app/controllers/events/categories_controller.rb` | **Modify** — migrate to `Core::PublicCommon` |
| `app/controllers/events/artists_controller.rb` | **Modify** — migrate to `Core::PublicCommon` |
| `app/controllers/events/venues_controller.rb` | **Modify** — migrate to `Core::PublicCommon` |
| `app/controllers/organizations/organizations_controller.rb` | **Modify** — migrate to `Core::PublicCommon` |
| `test/controllers/core/public_common_test.rb` | **Create** — concern-level controller tests |
| `test/integration/events/categories_test.rb` | **Modify** — add order/filter coverage |
| `test/integration/events/venues_test.rb` | **Modify** — add filter/order coverage |
| `test/integration/events/artists_test.rb` | **Modify** — add order coverage |
| `test/integration/organizations/organizations_test.rb` | **Modify** — add order coverage |

### Task 1: Create `Core::PublicCommon` concern

**Files:**
- Create: `app/controllers/concerns/core/public_common.rb`
- Test: `test/controllers/core/public_common_test.rb`

- [ ] **Step 1: Create the concern**

```ruby
module Core
  module PublicCommon
    extend ActiveSupport::Concern

    include Core::Pagination
    include Core::Filterable

    included do
      class_attribute :model_class, default: nil
      class_attribute :list_serializer, default: nil
      class_attribute :detail_serializer, default: nil
    end

    def index
      records = base_scope
      records = filter_records(records) if searchable?
      records = apply_catalog_filters(records)
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
      record = detail_scope.find(params[:id])
      render_success(
        data: record,
        serializer_options: { serializer: self.class.detail_serializer }
      )
    end

    private

    def base_scope
      self.class.model_class.all
    end

    def detail_scope
      base_scope
    end

    def apply_catalog_filters(scope)
      scope
    end

    def searchable?
      false
    end
  end
end
```

- [ ] **Step 2: Write concern-level tests**

```ruby
require "test_helper"

class Core::PublicCommonTest < ActionDispatch::IntegrationTest
  def setup
    # Use a real public catalog endpoint (categories — simplest, no follow actions)
    @endpoint = "/events/categories"
  end

  test "index returns success" do
    get @endpoint
    assert_response :success
  end

  test "index defaults to limit(25) when no page param" do
    create_list(:events_category, 30)
    get @endpoint
    body = response.parsed_body
    assert_equal 25, body["data"].size
  end

  test "index paginates when page param is present" do
    create_list(:events_category, 30)
    get @endpoint, params: { page: 1, per_page: 10 }
    body = response.parsed_body
    assert_equal 10, body["data"].size
    assert_equal 1, body.dig("meta", "pagination", "current_page")
    assert_equal 10, body.dig("meta", "pagination", "per_page")
    assert_equal 30, body.dig("meta", "pagination", "total_count")
  end

  test "index orders by id desc by default" do
    cat_a = create(:events_category)
    cat_b = create(:events_category)
    cat_c = create(:events_category)
    get @endpoint
    ids = response.parsed_body["data"].map { |r| r["id"] }
    expected = [cat_c, cat_b, cat_a].map(&:id).map(&:to_s)
    assert_equal expected, ids
  end

  test "index accepts allowlisted order_by" do
    cat_a = create(:events_category, name: "Zoo")
    cat_b = create(:events_category, name: "Alpha")
    get @endpoint, params: { order_by: "name", order_direction: "asc" }
    ids = response.parsed_body["data"].map { |r| r["id"] }
    expected = [cat_b, cat_a].map(&:id).map(&:to_s)
    assert_equal expected, ids
  end

  test "index ignores invalid order_by (falls back to default)" do
    create(:events_category)
    get @endpoint, params: { order_by: "invalid_column" }
    assert_response :success
  end

  test "show returns success" do
    category = create(:events_category)
    get "#{@endpoint}/#{category.id}"
    assert_response :success
    assert_equal category.id.to_s, response.parsed_body.dig("data", "id")
  end

  test "show returns 404 for nonexistent record" do
    get "#{@endpoint}/nonexistent"
    assert_response :not_found
  end
end
```

- [ ] **Step 3: Run concern tests (they'll fail — no model_class/list_serializer set)**

Run: `rails test test/controllers/core/public_common_test.rb`
Expected: FAIL with "nil is not a valid value"

- [ ] **Step 4: Commit**

```bash
git add app/controllers/concerns/core/public_common.rb test/controllers/core/public_common_test.rb
git commit -m "feat: add Core::PublicCommon concern for public catalog endpoints"
```

### Task 2: Migrate Events::CategoriesController

**Files:**
- Modify: `app/controllers/events/categories_controller.rb`
- Test: `test/integration/events/categories_test.rb` (verify existing tests still pass)

- [ ] **Step 1: Rewrite controller to use PublicCommon**

```ruby
module Events
  class CategoriesController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Events::Category
    self.list_serializer = Events::Public::CategoryListSerializer
    self.detail_serializer = Events::Public::CategoryDetailSerializer

    private

    def base_scope
      self.class.model_class.active
    end

    def allowed_order_columns
      %w[id name created_at]
    end
  end
end
```

- [ ] **Step 2: Run existing integration tests to confirm no regression**

Run: `rails test test/integration/events/categories_test.rb`
Expected: PASS (same assertions, same response shapes)

- [ ] **Step 3: Commit**

```bash
git add app/controllers/events/categories_controller.rb
git commit -m "feat(categories): migrate to Core::PublicCommon"
```

### Task 3: Migrate Events::ArtistsController

**Files:**
- Modify: `app/controllers/events/artists_controller.rb`

- [ ] **Step 1: Rewrite controller**

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
      self.class.model_class.active.with_attached_profile
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

- [ ] **Step 2: Run existing integration tests**

Run: `rails test test/integration/events/artists_test.rb`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add app/controllers/events/artists_controller.rb
git commit -m "feat(artists): migrate to Core::PublicCommon"
```

### Task 4: Migrate Events::VenuesController

**Files:**
- Modify: `app/controllers/events/venues_controller.rb`
- Modify: `test/integration/events/venues_test.rb` (add filter coverage)

- [ ] **Step 1: Rewrite controller**

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
      self.class.model_class.active.with_attached_profile.with_attached_photos
    end

    def detail_scope
      self.class.model_class.with_attached_profile.with_attached_photos
    end

    def allowed_order_columns
      %w[id name city country created_at]
    end

    def followable_class
      Events::Venue
    end

    def apply_catalog_filters(scope)
      scope = scope.by_city(params[:city]) if params[:city].present?
      scope = scope.by_country(params[:country]) if params[:country].present?
      scope = scope.verified if params[:verified] == "true"
      scope
    end
  end
end
```

- [ ] **Step 2: Run existing integration tests**

Run: `rails test test/integration/events/venues_test.rb`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add app/controllers/events/venues_controller.rb
git commit -m "feat(venues): migrate to Core::PublicCommon with city/country/verified filters"
```

### Task 5: Migrate Organizations::OrganizationsController

**Files:**
- Modify: `app/controllers/organizations/organizations_controller.rb`

- [ ] **Step 1: Rewrite controller**

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
      self.class.model_class.all.with_attached_profile
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

- [ ] **Step 2: Run existing integration tests**

Run: `rails test test/integration/organizations/organizations_test.rb`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add app/controllers/organizations/organizations_controller.rb
git commit -m "feat(organizations): migrate to Core::PublicCommon"
```

### Task 6: Run full test suite and verify

- [ ] **Step 1: Run full suite**

Run: `rails test`
Expected: 700+ tests, 0 failures

- [ ] **Step 2: Commit if any additional changes**

```bash
git add -A
git commit -m "test: add ordering/filter coverage for public catalog controllers"
```
