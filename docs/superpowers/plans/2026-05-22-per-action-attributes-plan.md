# Per-Action & Per-Role Attribute Visibility Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans`.

**Goal:** Add per-action (lightweight index, full show) and per-role (attendees hide timestamps) attribute filtering to API responses via serializer-driven visibility.

**Architecture:** Controller declares `serializer_fields` (per-action profile). Policy declares `visible_attributes_for(record:, action:)` (per-role restriction). `Core::JsonResponse` resolves the intersection. A new `Core::AttributeVisibilitySerializer` concern slices AMS output. Associations stay controlled by existing `default_serializer_includes`.

**Tech Stack:** Rails 8.1, ActiveModelSerializers, Pundit

---

### Task 1: Add `serializer_fields` + resolution logic to `Core::JsonResponse`

**Files:**
- Modify: `app/controllers/concerns/core/json_response.rb`

- [ ] **Step 1: Add `serializer_fields` default and resolution helpers**

Add to the concern:

```ruby
def serializer_fields
  nil
end

def resolved_visible_attributes(data)
  controller_fields = serializer_fields&.dig(action_name.to_sym)
  policy_fields = policy_visible_attributes_for(data)

  return nil if controller_fields.nil? && policy_fields.nil?
  return controller_fields.map(&:to_sym) if policy_fields.nil?
  return policy_fields.map(&:to_sym) if controller_fields.nil?

  controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
end

def policy_visible_attributes_for(data)
  return nil unless data.is_a?(ActiveRecord::Base) || data.is_a?(ActiveRecord::Relation)

  target = data.is_a?(ActiveRecord::Relation) ? @clazz&.new : data
  return nil unless target

  pol = policy(target)
  return nil unless pol&.respond_to?(:visible_attributes_for)

  pol.visible_attributes_for(record: target, action: action_name)
end
```

- [ ] **Step 2: Update `render_success` to pass `visible_attributes`**

Find the `serialize` call inside `render_success` and merge `visible_attributes` before passing:

```ruby
response[:data] = serialize(data, serializer_options.except(:pagination).merge(
  visible_attributes: resolved_visible_attributes(data)
)) unless data.nil?
```

- [ ] **Step 3: Run existing tests to verify no regression**

Run: `rails test`
Expected: All 73 tests pass (no behavior change since defaults return nil).

- [ ] **Step 4: Commit**

```bash
git add app/controllers/concerns/core/json_response.rb
git commit -m "feat: add serializer_fields and visible_attributes resolution to JsonResponse"
```

---

### Task 2: Add `visible_attributes_for` default to `Core::ApplicationPolicy`

**Files:**
- Modify: `app/policies/core/application_policy.rb`

- [ ] **Step 1: Add the default method**

Add to `Core::ApplicationPolicy`:

```ruby
def visible_attributes_for(record:, action:)
  nil
end
```

- [ ] **Step 2: Run tests**

Run: `rails test`
Expected: 73 tests, all pass.

- [ ] **Step 3: Commit**

```bash
git add app/policies/core/application_policy.rb
git commit -m "feat: add visible_attributes_for default to ApplicationPolicy"
```

---

### Task 3: Create `Core::AttributeVisibilitySerializer` concern

**Files:**
- Create: `app/serializers/concerns/core/attribute_visibility_serializer.rb`
- Modify: `app/serializers/events/category_serializer.rb`

- [ ] **Step 1: Create the concern**

```ruby
module Core
  module AttributeVisibilitySerializer
    def attributes(*args)
      data = super
      allowed = instance_options[:visible_attributes]
      return data if allowed.blank?

      allowed_keys = allowed.map(&:to_sym)
      data.slice(*allowed_keys)
    end
  end
end
```

- [ ] **Step 2: Include in CategorySerializer**

```ruby
module Events
  class CategorySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at
    has_many :audit_logs, serializer: Core::AuditLogSerializer
  end
end
```

- [ ] **Step 3: Run tests**

Run: `rails test`
Expected: 73 pass (defaults still nil everywhere, no filtering happens).

- [ ] **Step 4: Commit**

```bash
git add app/serializers/concerns/core/attribute_visibility_serializer.rb app/serializers/events/category_serializer.rb
git commit -m "feat: add AttributeVisibilitySerializer concern"
```

---

### Task 4: Add `serializer_fields` to controller + `visible_attributes_for` to policy

**Files:**
- Modify: `app/controllers/events/categories_controller.rb`
- Modify: `app/policies/events/category_policy.rb`

- [ ] **Step 1: Add `serializer_fields` to CategoriesController**

```ruby
def serializer_fields
  {
    index:  %i[id name slug],
    show:   %i[id name description slug metadata active created_at updated_at],
    create: %i[id name slug],
    update: %i[id name slug]
  }
end
```

- [ ] **Step 2: Add `visible_attributes_for` to CategoryPolicy**

```ruby
def visible_attributes_for(record:, action:)
  return nil unless action.to_sym == :show
  return nil if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
  %i[id name description slug metadata active]
end
```

- [ ] **Step 3: Run tests to see what breaks**

Run: `rails test test/integration/events/categories_test.rb -v`
Expected: attribute presence/absence tests will fail because existing `resource_test` auto-generated `check_attributes` from `column_names` but now responses are filtered.

- [ ] **Step 4: Commit**

```bash
git add app/controllers/events/categories_controller.rb app/policies/events/category_policy.rb
git commit -m "feat: add serializer_fields and visible_attributes_for to categories"
```

---

### Task 5: Add explicit integration tests for attribute visibility

**Files:**
- Modify: `test/integration/events/categories_test.rb`

- [ ] **Step 1: Add tests for per-action attribute presence**

Add before the `resource_test` call:

```ruby
class EventsCategoriesTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  test "index returns only the lightweight field profile" do
    get "/events/categories", headers: admin_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    data.each { |item| assert_equal %w[id name slug].sort, item.keys.sort }
  end

  test "show returns full profile for admin" do
    record = Events::Category.first
    get "/events/categories/#{record.id}", headers: admin_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert data.key?("created_at")
    assert data.key?("updated_at")
  end

  test "show hides timestamps for attendee" do
    record = Events::Category.first
    get "/events/categories/#{record.id}", headers: attendee_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert_not data.key?("created_at")
    assert_not data.key?("updated_at")
  end

  test "create returns only summary fields" do
    post "/events/categories",
      params: { category: { name: "Test #{SecureRandom.hex(4)}", description: "Testing" } },
      headers: admin_headers, as: :json
    assert_response :created
    data = JSON.parse(response.body).fetch("data")
    assert_equal %w[id name slug].sort, data.keys.sort
  end

  resource_test
end
```

- [ ] **Step 2: Run tests**

Run: `rails test test/integration/events/categories_test.rb -v`
Expected: All tests pass (including new attribute visibility tests + auto-generated resource_test tests).

- [ ] **Step 3: Full suite**

Run: `rails test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/integration/events/categories_test.rb
git commit -m "test: add attribute visibility integration tests for categories"
```

---

### Task 6: Extend `resource_test` with auto-detection of `serializer_fields`

**Files:**
- Modify: `test/support/core/resource_test.rb`

- [ ] **Step 1: Read `serializer_fields` from controller in Metadata**

In `resolve_default_check_attributes`, check for controller `serializer_fields` first:

```ruby
def resolve_default_check_attributes
  controller_fields = @controller_class&.new&.serializer_fields rescue nil

  if controller_fields
    resolver = Core::AttributeVisibilitySerializer
    serializer_class = "#{@model_class.name}Serializer".constantize
    full_set = serializer_class._attributes.map(&:to_s) rescue @model_class.column_names

    controller_fields.each do |action, attrs|
      attr_strings = attrs.map(&:to_s)
      @check_attributes[action] ||= attr_strings
      absent = full_set - attr_strings
      @check_attributes[:"#{action}_absent"] ||= absent if absent.any?
    end
    return
  end

  columns = @model_class.column_names - %w[id created_at updated_at] rescue []
  @check_attributes[:show] ||= columns if columns.any?
  @check_attributes[:index] ||= columns if columns.any?
end
```

- [ ] **Step 2: Add absence test generation**

Add a new method `generate_absence_tests` called from `resource_test`:

```ruby
def generate_absence_tests(meta)
  meta.actions.each do |action|
    absent = meta.check_attributes[:"#{action}_absent"]
    next unless absent&.any?

    test "#{action} excludes hidden attributes" do
      record = resolve_record(action, meta)
      path = action == :index ? meta.path : "#{meta.path}/#{record.id}"
      params = resolve_params(action, meta, record)

      public_send(http_method_for(action), path, params: params, headers: admin_headers, as: :json)
      assert_response :success

      data = action == :index ? JSON.parse(response.body).dig("data")&.first : JSON.parse(response.body).dig("data")
      absent.each { |attr| assert_not data.key?(attr), "Did not expect #{attr} in #{action} response" }
    end
  end
end

def http_method_for(action)
  { index: :get, show: :get, create: :post, update: :patch, destroy: :delete }[action]
end
```

Call it from `resource_test`:

```ruby
def resource_test(**options)
  meta = Metadata.new(self, options)
  meta.build

  meta.actions.each { |action| generate_tests(action, meta) }
  generate_show_extras(meta)
  generate_index_extras(meta)
  generate_absence_tests(meta)
  generate_destroy_test(meta)
end
```

- [ ] **Step 3: Run tests**

Run: `rails test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/support/core/resource_test.rb
git commit -m "feat: auto-detect serializer_fields in resource_test"
```

---

### Task 7: Update docs

**Files:**
- Modify: `docs/TEST_HELPERS_GUIDE.md`

- [ ] **Step 1: Update the guide**

Add a section documenting:
- `serializer_fields` in controllers
- `visible_attributes_for` in policies
- How `resource_test` auto-detects and tests them
- The `check_attributes` option for manual override

- [ ] **Step 2: Commit**

```bash
git add docs/TEST_HELPERS_GUIDE.md
git commit -m "docs: update TEST_HELPERS_GUIDE with attribute visibility features"
```

---

### Task 8: Final verification

- [ ] **Run full test suite**

Run: `rails test`
Expected: All tests pass, 0 failures, 0 errors.

- [ ] **Run a quick manual check**

```bash
rails runner "
  c = Events::CategoriesController.new
  puts c.serializer_fields.inspect
  puts 'OK: serializer_fields works'
"
```

Expected: Prints `{:index=>[:id, :name, :slug], :show=>[:id, :name, :description, :slug, :metadata, :active, :created_at, :updated_at], :create=>[:id, :name, :slug], :update=>[:id, :name, :slug]}` and "OK: serializer_fields works".
