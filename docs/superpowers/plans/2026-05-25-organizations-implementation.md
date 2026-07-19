# Organizations Domain — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Implement Organizations domain (models, policies, serializers, controllers, tests) with nested resource support in Core::Common.

**Architecture:** Two models under `Organizations` module following existing `Events` conventions. Nested routing with parent-scoped CRUD via `Core::Common`. Authorization through organization membership (owner role), not global permissions.

**Tech Stack:** Rails 8.1, PostgreSQL, Pundit, ActiveModelSerializers, Minitest + Core::ResourceTest.

---

### Task 1: Core::Common — Add Nested Resource Support

**Files:**
- Modify: `app/controllers/concerns/core/common.rb`

Add three class attributes after existing `model_class`:
```ruby
class_attribute :model_class, default: nil
class_attribute :parent_class, default: nil
class_attribute :parent_param, default: nil
class_attribute :parent_association, default: nil
```

Reorder `before_action` to add `set_parent` between `set_clazz` and `set_object`:
```ruby
before_action :set_clazz
before_action :set_parent
before_action :set_object, only: %i[show update destroy]
```

Add `set_parent` and `child_association` private methods:
```ruby
def set_parent
  return unless self.class.parent_class

  param_name = self.class.parent_param || :"#{self.class.parent_class.model_name.singular}_id"
  @parent = self.class.parent_class.find(params[param_name])
end

def child_association
  self.class.parent_association || @clazz.model_name.plural.to_sym
end
```

Modify `set_object` to scope through parent when in nested mode:
```ruby
def set_object
  if self.class.parent_class
    @obj = @parent.public_send(child_association)
            .includes(eager_loaded_associations)
            .find(params[:id])
  else
    @obj = @clazz.includes(eager_loaded_associations).find(params[:id])
  end
end
```

Modify `index` to authorize child with parent context and scope through parent:
```ruby
def index
  if self.class.parent_class
    authorize @parent.public_send(child_association).new, :index?
    data, serializer_options = resolve_block_result(default: policy_scope(@parent.public_send(child_association)))
  else
    authorize @clazz.new, :index? unless skip_authorization_for_action?
    data, serializer_options = resolve_block_result(default: policy_scope(@clazz))
  end

  data = data.includes(eager_loaded_associations) if data.respond_to?(:includes)
  data = filter_records(data)
  data = apply_ordering(data)

  total_count = data.count if paginated_request?
  data = apply_pagination(data) if paginated_request?

  serializer_options[:include] ||= eager_loaded_associations

  pagination = paginated_request? ? pagination_metadata(total_count) : nil
  render_success(data: data, serializer_options: serializer_options, pagination: pagination)
end
```

Modify `create` to build through parent when in nested mode, authorize after build:
```ruby
def create
  object = if self.class.parent_class
    @parent.public_send(child_association).new(model_params)
  else
    @clazz.new(model_params)
  end

  authorize object unless skip_authorization_for_action?

  ActiveRecord::Base.transaction do
    if object.save
      @obj = object
      after_create_hook(object) if respond_to?(:after_create_hook, true)

      object = @clazz.includes(eager_loaded_associations).find(object.id)
      @obj = object

      serializer_options[:include] ||= eager_loaded_associations

      render_success(data: object, serializer_options: serializer_options, status: :created)
    else
      render_error(errors: object.errors, status: :unprocessable_entity)
    end
  end
rescue ActiveRecord::RecordInvalid => error
  render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
rescue ActiveRecord::RecordNotFound => error
  render_error(error.message, status: :not_found)
rescue Pundit::NotAuthorizedError
  raise
end
```

---

### Task 2: Migrations — Organizations Tables

**Files:**
- Create: `db/migrate/2026_05_25_create_organizations_organizations.rb`
- Create: `db/migrate/2026_05_25_create_organizations_memberships.rb`

#### `2026_05_25_create_organizations_organizations.rb`:
```ruby
class CreateOrganizationsOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations_organizations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.timestamps
    end

    add_index :organizations_organizations, :slug, unique: true
  end
end
```

#### `2026_05_25_create_organizations_memberships.rb`:
```ruby
class CreateOrganizationsMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations_memberships, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, foreign_key: { to_table: :core_users }, type: :uuid
      t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }, type: :uuid
      t.integer :role, null: false
      t.timestamps
    end

    add_index :organizations_memberships, [:user_id, :organization_id], unique: true,
              name: "idx_org_memberships_on_user_and_org"

    execute <<-SQL
      CREATE UNIQUE INDEX idx_one_owner_per_org
        ON organizations_memberships (organization_id)
        WHERE role = 0;
    SQL
  end
end
```

---

### Task 3: Models — Organization + Membership

**Files:**
- Create: `app/models/organizations/application_record.rb`
- Create: `app/models/organizations/organization.rb`
- Create: `app/models/organizations/membership.rb`

#### `application_record.rb`:
```ruby
module Organizations
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
```

#### `organization.rb`:
```ruby
module Organizations
  class Organization < Organizations::ApplicationRecord
    self.table_name = "organizations_organizations"

    include Core::AuditableModel
    include Core::Slugable
    slugable source: :name, target: :slug

    has_many :memberships, class_name: "Organizations::Membership", dependent: :destroy
    has_one :owner_membership, -> { where(role: :owner) }, class_name: "Organizations::Membership"

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true

    def owner
      owner_membership&.user
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name slug description created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[memberships]
    end
  end
end
```

#### `membership.rb`:
```ruby
module Organizations
  class Membership < Organizations::ApplicationRecord
    self.table_name = "organizations_memberships"

    belongs_to :user, class_name: "Core::User"
    belongs_to :organization, class_name: "Organizations::Organization"

    enum role: { owner: 0, admin: 1, member: 2 }

    validates :role, presence: true
    validates :role, uniqueness: { scope: :organization_id,
                                    message: "already exists for this organization" },
             if: -> { owner? }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id organization_id role created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user organization]
    end
  end
end
```

---

### Task 4: Policies — Organization + Membership

**Files:**
- Create: `app/policies/organizations/organization_policy.rb`
- Create: `app/policies/organizations/membership_policy.rb`

#### `organization_policy.rb`:
```ruby
module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      record.owner == user || user.super_admin?
    end

    def create?
      true
    end

    def update?
      record.owner == user || user.super_admin?
    end

    def destroy?
      record.owner == user || user.super_admin?
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user.super_admin?
        scope.joins(:memberships)
             .where(organizations_memberships: { user_id: user.id, role: 0 })
      end
    end
  end
end
```

#### `membership_policy.rb`:
```ruby
module Organizations
  class MembershipPolicy < Core::ApplicationPolicy
    def index?
      org_id = record.organization_id || record.organization&.id
      return false unless org_id
      Organizations::Membership.exists?(user_id: user.id, organization_id: org_id, role: :owner) || user.super_admin?
    end

    def show?
      record.organization&.owner == user || user.super_admin?
    end

    def create?
      record.organization&.owner == user || user.super_admin?
    end

    def update?
      record.organization&.owner == user || user.super_admin?
    end

    def destroy?
      record.organization&.owner == user || user.super_admin?
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user.super_admin?
        org_ids = Organizations::Organization.joins(:memberships)
                     .where(organizations_memberships: { user_id: user.id, role: :owner })
                     .select(:id)
        scope.where(organization_id: org_ids)
      end
    end
  end
end
```

---

### Task 5: Serializers — Organization + Membership

**Files:**
- Create: `app/serializers/organizations/organization_serializer.rb`
- Create: `app/serializers/organizations/membership_serializer.rb`

#### `organization_serializer.rb`:
```ruby
module Organizations
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    attributes :id, :name, :slug, :description, :created_at
    has_many :memberships, serializer: Organizations::MembershipSerializer
  end
end
```

#### `membership_serializer.rb`:
```ruby
module Organizations
  class MembershipSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    attributes :id, :role, :created_at
    belongs_to :user, serializer: Core::UserAuthSerializer
  end
end
```

---

### Task 6: Controllers — Base + Organizations + Memberships

**Files:**
- Create: `app/controllers/organizations/application_controller.rb`
- Create: `app/controllers/organizations/organizations_controller.rb`
- Create: `app/controllers/organizations/memberships_controller.rb`

#### `application_controller.rb`:
```ruby
module Organizations
  class ApplicationController < Core::ApplicationController
  end
end
```

#### `organizations_controller.rb`:
```ruby
module Organizations
  class OrganizationsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController
    self.model_class = Organizations::Organization
    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:organization).permit(:name, :description)
    end

    def allowed_order_columns
      %w[id name slug created_at updated_at]
    end

    def after_create_hook(organization)
      organization.memberships.create!(user: current_user, role: :owner)
    end

    def serializer_profile
      {
        index:  { fields: %i[id name slug description created_at] },
        show:   { fields: %i[id name slug description created_at] },
        create: { fields: %i[id name slug description created_at] },
        update: { fields: %i[id name slug description created_at] }
      }
    end
  end
end
```

#### `memberships_controller.rb`:
```ruby
module Organizations
  class MembershipsController < Organizations::ApplicationController
    include Core::Common
    self.model_class = Organizations::Membership
    self.parent_class = Organizations::Organization

    private

    def model_params
      params.require(:membership).permit(:user_id, :role)
    end

    def allowed_order_columns
      %w[id role created_at updated_at]
    end

    def serializer_profile
      {
        index:  { fields: %i[id role created_at] },
        show:   { fields: %i[id role created_at] },
        create: { fields: %i[id role created_at] },
        update: { fields: %i[id role created_at] }
      }
    end
  end
end
```

---

### Task 7: Routes + Locales + Fixtures + Test Helper

**Files:**
- Modify: `config/routes.rb`
- Create: `config/locales/organizations/organization.en.yml`
- Create: `config/locales/organizations/membership.en.yml`
- Create: `test/fixtures/organizations_organizations.yml`
- Create: `test/fixtures/organizations_memberships.yml`
- Modify: `test/test_helper.rb`

#### Routes — add after events namespace:
```ruby
namespace :organizations do
  resources :organizations, except: %i[new edit] do
    resources :memberships, except: %i[new edit], controller: "memberships"
  end
end
```

#### Locales — `organization.en.yml`:
```yaml
en:
  organization:
    success:
      index: "Organizations retrieved successfully"
      show: "Organization retrieved successfully"
      create: "Organization created successfully"
      update: "Organization updated successfully"
      destroy: "Organization deleted successfully"
    errors:
      create: "Failed to create organization"
      update: "Failed to update organization"
      destroy: "Failed to delete organization"
```

#### Locales — `membership.en.yml`:
```yaml
en:
  membership:
    success:
      index: "Memberships retrieved successfully"
      show: "Membership retrieved successfully"
      create: "Membership created successfully"
      update: "Membership updated successfully"
      destroy: "Membership deleted successfully"
    errors:
      create: "Failed to create membership"
      update: "Failed to update membership"
      destroy: "Failed to delete membership"
```

#### Fixtures — `organizations_organizations.yml`:
```yaml
one:
  id: a1111111-1111-1111-1111-111111111111
  name: First Organization
  slug: first-organization
  description: The very first organization

two:
  id: a2222222-2222-2222-2222-222222222222
  name: Second Organization
  slug: second-organization
  description: The second organization
```

#### Fixtures — `organizations_memberships.yml`:
```yaml
owner_one:
  id: b1111111-1111-1111-1111-111111111111
  user_id: <%= ActiveRecord::FixtureSet.identify(:super_admin, :uuid) %>
  organization_id: a1111111-1111-1111-1111-111111111111
  role: 0

owner_two:
  id: b2222222-2222-2222-2222-222222222222
  user_id: <%= ActiveRecord::FixtureSet.identify(:core_admin, :uuid) %>
  organization_id: a2222222-2222-2222-2222-222222222222
  role: 0
```

#### Test Helper — add to `set_fixture_class`:
```ruby
organizations_organizations: Organizations::Organization,
organizations_memberships: Organizations::Membership,
```

---

### Task 8: Integration Tests

**Files:**
- Create: `test/integration/organizations/organizations_test.rb`
- Create: `test/integration/organizations/memberships_test.rb`

#### `organizations_test.rb`:
```ruby
require "test_helper"

class OrganizationsOrganizationsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test create_params: -> { { organization: { name: "New Org" } } },
               update_params: ->(record) { { organization: { name: "Updated Org" } } }
end
```

#### `memberships_test.rb`:
```ruby
require "test_helper"

class OrganizationsMembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test path: "/organizations/organizations/#{organizations_organizations(:one).id}/memberships",
               model: Organizations::Membership,
               create_params: -> {
                 user = core_users(:attendee)
                 { membership: { user_id: user.id, role: "member" } }
               },
               update_params: ->(record) {
                 { membership: { role: "member" } }
               },
               record: -> { organizations_organizations(:one).memberships.first }
end
```

---

### Task 9: Custom Authorization Tests — Owner vs Non-Owner

**Files:**
- Modify: `test/integration/organizations/organizations_test.rb`
- Modify: `test/integration/organizations/memberships_test.rb`

Add to `organizations_test.rb` (after the `resource_test` call):
```ruby
test "owner can show own organization" do
  org = organizations_organizations(:one)
  user = core_users(:super_admin)  # owner via fixture
  get "/organizations/organizations/#{org.id}", headers: token_headers_for(user), as: :json
  assert_response :success
end

test "non-owner cannot show organization" do
  org = organizations_organizations(:one)
  user = core_users(:attendee)  # not an owner
  get "/organizations/organizations/#{org.id}", headers: token_headers_for(user), as: :json
  assert_response :forbidden
end

test "non-owner index returns empty list" do
  user = core_users(:attendee)
  get "/organizations/organizations", headers: token_headers_for(user), as: :json
  assert_response :success
  assert_equal [], JSON.parse(response.body).dig("data")
end

test "after_create_hook creates owner membership" do
  user = core_users(:attendee)
  post "/organizations/organizations",
       params: { organization: { name: "My Org" } },
       headers: token_headers_for(user), as: :json
  assert_response :created
  org = Organizations::Organization.find(JSON.parse(response.body).dig("data", "id"))
  assert_equal user.id, org.owner.id
end
```

Note: `token_headers_for` is a helper defined in `Core::AuthTestHelpers` (included via `Core::ResourceTest`).

---

### Execution Order

1. Task 1 — Core::Common changes (no migrations needed)
2. Task 2 — Migrations (run after writing)
3. Task 3 — Models
4. Task 4 — Policies
5. Task 5 — Serializers
6. Task 6 — Controllers
7. Task 7 — Routes, Locales, Fixtures, Test Helper
8. Tasks 8+9 — Tests
9. Run full test suite, fix any failures
