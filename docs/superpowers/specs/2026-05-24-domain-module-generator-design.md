# Domain Module Generator

**Date:** 2026-05-24
**Status:** Draft

## Overview

A Rails generator that scaffolds a complete domain module — model, migration, controller, serializer, policy, tests, fixtures, and route — in one command.

## Usage

```bash
rails generate domain_module Events::Event name:string description:text event:belongs_to[Events::Event] --auditable --slug-source=name
rails generate domain_module Ticketing::Ticket purchaser:belongs_to[Customers::Customer] status:string --no-auditable
rails generate domain_module Orders::Order ticket:belongs_to[Ticketing::Ticket] buyer:belongs_to[Customers::Customer] quantity:integer --no-slug
```

### Arguments

| Arg | Description | Example |
|-----|-------------|---------|
| `NAME` | Namespaced model name (required) | `Events::Event` |
| `COLUMNS` | Standard Rails attribute types | `name:string description:text active:boolean` |

Column types: `string`, `text`, `integer`, `decimal`, `float`, `boolean`, `date`, `datetime`, `jsonb`, `belongs_to`.

`belongs_to` creates a UUID foreign key column and adds a `belongs_to` declaration to the model and serializer. For cross-namespace references, specify the target class in brackets: `event:belongs_to[Events::Event]`. Without brackets, the class name is inferred as `Namespace::Name.camelize` (same-namespace).

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--auditable` / `--no-auditable` | `--auditable` | Include Core::AuditableModel + AuditableController |
| `--slug` / `--no-slug` | `--no-slug` | Enable slugable (source defaults to `name`) |
| `--slug-source=COL` | — | Override slug source column (implies `--slug`) |
| `--skip-migration` | false | Skip creating the migration file |
| `--skip-routes` | false | Skip adding route to routes.rb |
| `--skip-tests` | false | Skip test/fixture files |
| `--interactive` / `--no-interactive` | `--interactive` | Prompt for missing flags when run interactively |

When `--interactive` (default) and a flag wasn't provided:
- **Auditable**: prompt "Auditable? (Y/n)"
- **Slugable**: prompt "Slugable? (y/N)" then "Source column? (default: name)"
- **Create base classes**: prompt if namespace is new: "Namespace `Ticketing` doesn't exist. Create base classes? (Y/n)"

When `--no-interactive`, all missing flags use their defaults — suitable for scripting.

## Generated files

For `rails generate domain_module Events::Event name:string description:text event:belongs_to[Events::Event] --auditable --slug-source=name`:

| # | File | Condition |
|---|------|-----------|
| 1 | `db/migrate/TIMESTAMP_create_events_events.rb` | Always (unless `--skip-migration`) |
| 2 | `app/models/events/application_record.rb` | Only if namespace files don't exist |
| 3 | `app/models/events/event.rb` | Always |
| 4 | `app/controllers/events/application_controller.rb` | Only if namespace files don't exist |
| 5 | `app/controllers/events/events_controller.rb` | Always |
| 6 | `app/serializers/events/event_serializer.rb` | Always |
| 7 | `app/policies/events/event_policy.rb` | Always |
| 8 | `test/fixtures/events_events.yml` | Always (unless `--skip-tests`) |
| 9 | `test/models/events/event_test.rb` | Always (unless `--skip-tests`) |
| 10 | `test/integration/events/events_test.rb` | Always (unless `--skip-tests`) |
| 11 | Route in `config/routes.rb` | Always (unless `--skip-routes`) |

### Migration

`db/migrate/TIMESTAMP_create_events_events.rb`

```ruby
class CreateEventsEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name
      t.text :description
      t.uuid :event_id  # for belongs_to
      t.jsonb :metadata, default: {}, null: false
      t.string :slug  # if slugable
      t.boolean :active, default: true, null: false  # if no boolean column provided
      t.timestamps
    end

    add_index :events_events, :slug, unique: true if slugable
    add_index :events_events, :active  # if active column exists
  end
end
```

Rules:
- UUID v7 primary key is always used
- `metadata` JSONB column is always added (app convention)
- `slug` column added only when `--slug` or `--slug-source` is set
- `active` boolean added only when no user-provided boolean column exists (convention for soft-toggle)
- `belongs_to` columns use plain `uuid` type (no FK constraint — avoids broken references across namespaces)
- Index on slug (unique) when slugable
- Index on boolean columns

### Model

`app/models/events/event.rb`

```ruby
module Events
  class Event < Events::ApplicationRecord
    self.table_name = "events_events"

    include Core::AuditableModel  # if auditable
    include Core::Slugable        # if slugable
    slugable source: :name, target: :slug  # if slugable, source from --slug-source

    belongs_to :event, class_name: "Events::Event"       # from event:belongs_to[Events::Event]

    validates :name, presence: true  # for each string/text column (optional — detect from migration null: false)
    validates :slug, presence: true, uniqueness: true  # if slugable

    scope :active, -> { where(active: true) }     # if active column exists
    scope :inactive, -> { where(active: false) }   # if active column exists
    scope :alphabetical, -> { order(:name) }       # if name column exists (convention)

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name description event_id slug active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event]
    end
  end
end
```

Rules:
- Table name derived from namespace pluralized + model name pluralized: `Events::Event` → `events_events`
- `metadata` column is always added by migration, should not be in `ransackable_attributes` (it's JSONB)
- `ransackable_associations` includes belongs_to associations
- Validations based on null: false columns (name presence is convention even if migration allows null)
- `Core::Slugable` is always assumed to be included in the model concern set

### Controller

`app/controllers/events/events_controller.rb`

```ruby
module Events
  class EventsController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController  # if auditable

    self.model_class = Events::Event

    auditable on: %i[create update destroy]  # if auditable

    private

    def model_params
      params.require(:event).permit(:name, :description, :event_id, :active, metadata: {})
    end

    def allowed_order_columns
      %w[id name description event_id slug active created_at updated_at]
    end

    def serializer_profile
      {
        index: {},
        show: {},
        create: {},
        update: {}
      }
    end
  end
end
```

Rules:
- `model_params` permits all non-primary-key, non-timestamp columns
- `belongs_to` columns are `_id` suffixed (e.g., `event_id`)
- `metadata: {}` is always added to permit (JSONB)
- `serializer_profile` starts empty — user customizes per module
- `allowed_order_columns` includes id, data columns, belongs_to _id columns, slug, active, created_at, updated_at (only if columns exist)

### Serializer

`app/serializers/events/event_serializer.rb`

```ruby
module Events
  class EventSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :name, :description, :id, :metadata, :active, :created_at, :updated_at, :slug
    belongs_to :event, class_name: "Events::Event"
  end
end
```

Rules:
- All non-internal columns as attributes (exclude audit log internals, etc.)
- `belongs_to` associations from `belongs_to` columns
- No `has_many` — added manually when needed

### Policy

`app/policies/events/event_policy.rb`

```ruby
module Events
  class EventPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    # Admin-only for mutating actions (generated by default)
    # User overrides these per business rules
    def create?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
    end

    def update?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
    end

    def destroy?
      user.has_role?("SUPER_ADMIN")
    end

    VISIBILITY = {}.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
```

## Generator Class

`lib/generators/domain_module/domain_module_generator.rb`

```ruby
class DomainModuleGenerator < Rails::Generators::NamedBase
  source_root File.expand_path("templates", __dir__)

  Column = Struct.new(:name, :type, :class_name) do
    def belongs_to?
      type == :belongs_to
    end

    def sample_value
      case type
      when :string    then "\"Sample #{name.humanize}\""
      when :text      then "\"Sample text for #{name.humanize}\""
      when :integer   then "1"
      when :decimal, :float then "1.0"
      when :boolean   then "true"
      when :date      then "Date.current"
      when :datetime  then "Time.current"
      when :jsonb     then "{}"
      end
    end

    def sample_update_value
      case type
      when :string    then "\"Updated #{name.humanize}\""
      when :text      then "\"Updated text for #{name.humanize}\""
      when :integer   then "2"
      when :decimal, :float then "2.0"
      when :boolean   then "false"
      when :date      then "Date.yesterday"
      when :datetime  then "1.day.ago"
      when :jsonb     then "{ updated: true }"
      end
    end
  end

  class_option :auditable, type: :boolean, default: true
  class_option :slug, type: :boolean, default: false
  class_option :slug_source, type: :string, default: nil
  class_option :skip_migration, type: :boolean, default: false
  class_option :skip_routes, type: :boolean, default: false
  class_option :skip_tests, type: :boolean, default: false
  class_option :interactive, type: :boolean, default: true

  # Implementation note: When `--interactive` (default), prompt for flags the user
  # didn't explicitly pass. Rails generators provide `options[:flag]` even when
  # defaults kick in — you cannot distinguish "user passed --auditable" from
  # "default kicked in" via `options` alone. Workaround: parse ARGV directly or
  # use a sentinel default (e.g., `default: :unset` then check `options[:auditable] == :unset`).
  # Sentinel defaults won't work for boolean `class_option` since Rails coerces
  # `:unset` to `true`. Use `type: :string` with `default: nil` for interactive-only flags,
  # or check `ARGV` for `--auditable` / `--no-auditable`.

  COLUMN_RE = /\A
    (\w+)                     # name
    :
    (string|text|integer|decimal|float|boolean|date|datetime|jsonb|belongs_to)
    (?:\[(\w+(?:::\w+)*)\])?  # optional bracketed class_name for belongs_to
  \z/x

  private

  def parsed_columns
    @parsed_columns ||= args[1..].map do |arg|
      if arg =~ COLUMN_RE
        Column.new($1, $2.to_sym, $3)
      else
        raise ArgumentError, "Invalid column format: #{arg}"
      end
    end
  end

  def data_columns
    parsed_columns.reject(&:belongs_to?)
  end

  def belongs_to_columns
    parsed_columns.select(&:belongs_to?)
  end

  def resolve_class_name(col)
    col.class_name || guess_class_name(col)
  end

  def guess_class_name(col)
    "#{namespace_path.camelize}::#{col.name.camelize}"
  end

  def has_name?
    data_columns.any? { |c| c.name == "name" }
  end

  def belongs_to_setup_erb
    belongs_to_columns.map { |c|
      klass = resolve_class_name(c)
      %(result = #{klass}.connection.execute("INSERT INTO \#{#{klass}.table_name} DEFAULT VALUES RETURNING id"); @#{c.name} = #{klass}.find(result.first["id"]))
    }.join("\n    ")
  end

  def belongs_to_fk_refs_erb
    belongs_to_columns.map { |c| "#{c.name}_id: @#{c.name}.id" }.join(", ")
  end

  def sample_all_create_params_erb
    parts = data_columns.map { |c| "#{c.name}: #{c.sample_value}" }
    parts += belongs_to_columns.map { |c| "#{c.name}_id: @#{c.name}.id" }
    parts.join(", ")
  end

  def sample_all_update_params_erb
    parts = []
    unless data_columns.empty?
      col = data_columns.first
      parts << "#{col.name}: #{col.sample_update_value}"
    end
    parts += belongs_to_columns.map { |c| "#{c.name}_id: @#{c.name}.id" }
    parts.join(", ")
  end

  def auditable?
    options[:auditable]
  end

  def slugable?
    options[:slug] || options[:slug_source].present?
  end

  def slug_source_column
    options[:slug_source] || "name"
  end

  def table_name
    [*class_path.map(&:underscore), plural_name].join("_")
  end

  def model_name
    class_name.demodulize
  end

  def namespace_path
    class_path.first
  end

  def model_file_path
    File.join(*class_path, file_name)
  end

  def controller_file_path
    File.join(*class_path, "#{plural_name}_controller")
  end

  def serializer_file_path
    File.join(*class_path, "#{file_name}_serializer")
  end

  def policy_file_path
    File.join(*class_path, "#{file_name}_policy")
  end

  def model_test_file_path
    File.join(*class_path, "#{file_name}_test")
  end

  def integration_test_file_path
    File.join(*class_path, "#{plural_name}_test")
  end

  def fixture_file_name
    table_name
  end

  def param_columns
    hash_cols = []
    scalar_cols = parsed_columns.map do |col|
      if col.belongs_to?
        ":#{col.name}_id"
      elsif col.type == :jsonb
        hash_cols << "#{col.name}: {}"
        nil
      else
        ":#{col.name}"
      end
    end.compact
    scalar_cols << ":active" unless data_columns.any? { |c| c.name == "active" }
    scalar_cols + hash_cols + ["metadata: {}"]
  end

  def ransackable_attributes_list
    %w[id] +
      data_columns.reject { |c| c.type == :jsonb }.map(&:name) +
      belongs_to_columns.map { |c| "#{c.name}_id" } +
      %w[slug active created_at updated_at].tap { |list|
        list.delete("active") if data_columns.any? { |c| c.name == "active" }
        list.delete("slug") unless slugable?
      }
  end

  def serialized_attributes_list
    base = %i[id metadata active created_at updated_at]
    base << :slug if slugable?
    (data_columns.map { |c| ":#{c.name}" } + base.map { |c| ":#{c}" }).uniq
  end
end
```

## Templates

### `migration.rb.tt`

```ruby
class Create<%= table_name.camelize %> < ActiveRecord::Migration[8.1]
  def change
    create_table :<%= table_name %>, id: :uuid, default: -> { "uuidv7()" } do |t|
<% data_columns.each do |col| %>
      t.<%= col.type %> :<%= col.name %>
<% end %>
<% belongs_to_columns.each do |col| %>
      t.uuid :<%= col.name %>_id
<% end %>
      t.jsonb :metadata, default: {}, null: false
<% if slugable? %>
      t.string :slug
<% end %>
<% unless data_columns.any? { |c| c.name == "active" } %>
      t.boolean :active, default: true, null: false
<% end %>
      t.timestamps
    end

<% if slugable? %>
    add_index :<%= table_name %>, :slug, unique: true
<% end %>
<% unless data_columns.any? { |c| c.name == "active" } %>
    add_index :<%= table_name %>, :active
<% end %>
  end
end
```

Notes:
- `belongs_to` columns use plain `uuid` type (no `foreign_key: true`) to avoid broken FK references across namespaces
- `data_columns` excludes `belongs_to` entries; they're handled by `belongs_to_columns`
- `metadata` column is always present
- `slug` and `active` handle the core concerns

### `model.rb.tt`

```ruby
module <%= namespace_path.camelize %>
  class <%= model_name %> < <%= namespace_path.camelize %>::ApplicationRecord
    self.table_name = "<%= table_name %>"

<% if auditable? %>
    include Core::AuditableModel
<% end %>
<% if slugable? %>
    include Core::Slugable
    slugable source: :<%= slug_source_column %>, target: :slug
<% end %>
<% belongs_to_columns.each do |col| %>
<%   if col.class_name %>
    belongs_to :<%= col.name %>, class_name: "<%= col.class_name %>"
<%   else %>
    belongs_to :<%= col.name %>
<%   end %>
<% end %>
<% if data_columns.any? { |c| c.name == "name" } %>
    validates :name, presence: true
<% end %>
<% if slugable? %>
    validates :slug, presence: true, uniqueness: true
<% end %>
<% unless data_columns.any? { |c| c.name == "active" } %>
    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }
<% end %>
<% if data_columns.any? { |c| c.name == "name" } %>
    scope :alphabetical, -> { order(:name) }
<% end %>

    def self.ransackable_attributes(_auth_object = nil)
      %w[<%= ransackable_attributes_list.join(" ") %>]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[<%= belongs_to_columns.map(&:name).join(" ") %>]
    end
  end
end
```

### `controller.rb.tt`

```ruby
module <%= namespace_path.camelize %>
  class <%= plural_name.camelize %>Controller < <%= namespace_path.camelize %>::ApplicationController
    include Core::Common
<% if auditable? %>
    include Core::AuditableController
<% end %>

    self.model_class = <%= class_name %>

<% if auditable? %>
    auditable on: %i[create update destroy]
<% end %>

    private

    def model_params
      params.require(:<%= model_name.underscore %>).permit(
        <%= param_columns.join(", ") %>
      )
    end

    def allowed_order_columns
      %w[<%= ransackable_attributes_list.join(" ") %>]
    end

    def serializer_profile
      {
        index: {},
        show: {},
        create: {},
        update: {}
      }
    end
  end
end
```

### `serializer.rb.tt`

```ruby
module <%= namespace_path.camelize %>
  class <%= model_name %>Serializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes <%= serialized_attributes_list.join(", ") %>
<% belongs_to_columns.each do |col| %>
<%   if col.class_name %>
    belongs_to :<%= col.name %>, class_name: "<%= col.class_name %>"
<%   else %>
    belongs_to :<%= col.name %>
<%   end %>
<% end %>
  end
end
```

### `policy.rb.tt`

```ruby
module <%= namespace_path.camelize %>
  class <%= model_name %>Policy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    def create?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
    end

    def update?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
    end

    def destroy?
      user.has_role?("SUPER_ADMIN")
    end

    VISIBILITY = {}.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
```

### `fixture.yml.tt`

```yaml
one:
  id: <%= SecureRandom.uuid %>
<% data_columns.each do |col| %>
<%   if col.type == :string %>
  <%= col.name %>: Sample <%= col.name.humanize %>
<%   elsif col.type == :text %>
  <%= col.name %>: Sample text for <%= col.name.humanize %>
<%   elsif col.type == :integer %>
  <%= col.name %>: 1
<%   elsif col.type == :decimal || col.type == :float %>
  <%= col.name %>: 1.0
<%   elsif col.type == :boolean %>
  <%= col.name %>: true
<%   elsif col.type == :date %>
  <%= col.name %>: <%= Date.current %>
<%   elsif col.type == :datetime %>
  <%= col.name %>: <%= Time.current %>
<%   end %>
<% end %>
  metadata: {}
<% if slugable? %>
  slug: sample-<%= model_name.underscore %>-one
<% end %>
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>

two:
  id: <%= SecureRandom.uuid %>
<% data_columns.each do |col| %>
<%   if col.type == :string %>
  <%= col.name %>: Another <%= col.name.humanize %>
<%   elsif col.type == :text %>
  <%= col.name %>: Another text for <%= col.name.humanize %>
<%   elsif col.type == :integer %>
  <%= col.name %>: 2
<%   elsif col.type == :decimal || col.type == :float %>
  <%= col.name %>: 2.0
<%   elsif col.type == :boolean %>
  <%= col.name %>: false
<%   elsif col.type == :date %>
  <%= col.name %>: <%= Date.current %>
<%   elsif col.type == :datetime %>
  <%= col.name %>: <%= Time.current %>
<%   end %>
<% end %>
  metadata: {}
<% if slugable? %>
  slug: another-<%= model_name.underscore %>-two
<% end %>
  active: true
  created_at: <%= Time.current %>
  updated_at: <%= Time.current %>
```

Fixture convention:
- All fixture IDs use `SecureRandom.uuid` (generated at generation time, not at test runtime)
- `belongs_to` FK values are intentionally omitted from fixture YAML
- FK values are provided at test time via `resource_test create_params:` / unit test `create!` arguments
- This avoids brittle cross-namespace fixture dependencies that would break if target fixtures don't exist

### `model_test.rb.tt`

```ruby
require "test_helper"

class <%= class_name %>Test < ActiveSupport::TestCase
<% if data_columns.any? { |c| c.name == "name" } %>
  test "requires name" do
    record = <%= class_name %>.new(name: nil)
    assert_not record.valid?
    assert_includes record.errors[:name], "can't be blank"
  end
<% end %>

<% if slugable? && data_columns.any? { |c| c.name == "name" } %>
<% unless belongs_to_columns.empty? %>
  setup do
    <%= belongs_to_setup_erb %>
  end

<% end %>
  test "generates slug from name automatically" do
    record = <%= class_name %>.create!(name: "Test <%= model_name.humanize %>", metadata: {}<%= ", #{belongs_to_fk_refs_erb}" unless belongs_to_columns.empty? %>)
    assert_equal "test-<%= model_name.underscore %>", record.slug
  end
<% end %>

  test "ransackable_attributes returns safe attributes" do
    expected = %w[<%= ransackable_attributes_list.join(" ") %>]
    assert_equal expected, <%= class_name %>.ransackable_attributes
  end

  test "ransackable_associations returns safe associations" do
    assert_equal <%= belongs_to_columns.any? ? "%w[#{belongs_to_columns.map(&:name).join(' ')}]" : '[]' %>, <%= class_name %>.ransackable_associations
  end
end
```

### `integration_test.rb.tt`

```ruby
require "test_helper"

class <%= class_path.map(&:camelize).join + plural_name.camelize %>Test < ActionDispatch::IntegrationTest
  include Core::ResourceTest

<% unless belongs_to_columns.empty? %>
  setup do
    <%= belongs_to_setup_erb %>
  end

<% end %>
<% if has_name? && belongs_to_columns.empty? %>
  resource_test
<% else %>
  resource_test create_params: -> { { <%= model_name.underscore %>: { <%= sample_all_create_params_erb %> } } },
               update_params: ->(record) { { <%= model_name.underscore %>: { <%= sample_all_update_params_erb %> } } }
<% end %>
end
```

### `application_record.rb.tt` (for new namespaces)

```ruby
module <%= namespace_path.camelize %>
  class ApplicationRecord < Core::ApplicationRecord
    self.abstract_class = true
  end
end
```

### `application_controller.rb.tt` (for new namespaces)

```ruby
module <%= namespace_path.camelize %>
  class ApplicationController < Core::ApplicationController
  end
end
```

### Route

Added to `config/routes.rb` via the generator's `route` method:

```ruby
namespace :<%= namespace_path.underscore %> do
  resources :<%= plural_name %>
end
```

For `Events::Event`: `namespace :events do resources :events end`.

## What the generator does NOT handle

These are intentionally left for manual editing after generation:

- **Custom associations** beyond `belongs_to` — `has_many`, `has_one`, `has_and_belongs_to_many`
- **Polymorphic associations**
- **Custom validations** beyond name presence and slug uniqueness
- **Custom scopes** beyond active/inactive/alphabetical
- **Custom permission logic** in policies beyond the admin default
- **VISIBILITY entries** — starts empty, user adds per-module
- **Database constraints** like unique indexes on non-slug columns
- **Serialization customization** like `association_fields` or `serializer_profile` entries
- **Services, jobs, mailers** — generated model is a CRUD scaffold only
- **belongs_to target setup** — generated tests use `INSERT ... DEFAULT VALUES RETURNING id` to create FK target records, which lets PostgreSQL use all column defaults. Targets with NOT NULL columns lacking DB defaults still require manual setup editing.
- **Cross-module test data** — setup for cross-namespace belongs_to targets assumes the referenced module and model exist. The generator does not create companion fixtures or models for targets.

## Files created

| File | Content |
|------|---------|
| `lib/generators/domain_module/domain_module_generator.rb` | Generator class |
| `lib/generators/domain_module/templates/migration.rb.tt` | Migration template |
| `lib/generators/domain_module/templates/model.rb.tt` | Model template |
| `lib/generators/domain_module/templates/controller.rb.tt` | Controller template |
| `lib/generators/domain_module/templates/serializer.rb.tt` | Serializer template |
| `lib/generators/domain_module/templates/policy.rb.tt` | Policy template |
| `lib/generators/domain_module/templates/fixture.yml.tt` | Fixture template |
| `lib/generators/domain_module/templates/model_test.rb.tt` | Model test template |
| `lib/generators/domain_module/templates/integration_test.rb.tt` | Integration test template |
| `lib/generators/domain_module/templates/application_record.rb.tt` | Base record template |
| `lib/generators/domain_module/templates/application_controller.rb.tt` | Base controller template |
| `lib/generators/domain_module/USAGE` | Help text |

## Verification

After implementing, verify by:

1. `rails generate domain_module Ticketing::Ticket name:string price_cents:integer --no-auditable`
2. Check all 10+ files created
3. `rails db:migrate` runs without error
4. `rails test test/models/ticketing/ticket_test.rb` passes
5. `rails test test/integration/ticketing/tickets_test.rb` passes
6. `rails destroy domain_module Ticketing::Ticket` reverses all files
7. `rails generate domain_module Events::Event name:string --interactive --no-slug` — verifies auditable prompt
