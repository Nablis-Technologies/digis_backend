# Generator: Component Selection & Sensitive Attribute Filter

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--only`/`--skip` component selection and sensitive attribute filtering to the domain module generator.

**Architecture:** Two independent additions to `DomainModuleGenerator`. Component selection uses `class_option :only` / `class_option :skip` with Thor array type, validated against a `VALID_COMPONENTS` constant. Sensitive filtering adds a `SENSITIVE_ATTRIBUTES` pattern list and filters `ransackable_attributes_list` to exclude matching column names.

**Tech Stack:** Rails 8.1 generator (Thor), Minitest

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `lib/generators/domain_module/domain_module_generator.rb` | Modify | Add `--only`/`--skip` options, validation, guards on each `create_*` method, `SENSITIVE_ATTRIBUTES` constant, filter in `ransackable_attributes_list` |
| `docs/DOMAIN_MODULE_GENERATOR.md` | Modify | Document new options and filtering behavior |

No template changes needed — both features operate at the generator level.

### Task 1: Add `--only` / `--skip` options with validation

**Files:**

- Modify: `lib/generators/domain_module/domain_module_generator.rb:36-42`
- Modify: `lib/generators/domain_module/domain_module_generator.rb:57-119` (guard each method)

- [ ] **Step 1: Add `VALID_COMPONENTS` constant and `--only`/`--skip` options**

Add after line 34 (the `Column` struct ends):

```ruby
  VALID_COMPONENTS = %w[
    migration model controller serializer policy
    fixture model_test integration_test route
  ].freeze
```

Add after the existing `class_option` lines (around line 42):

```ruby
  class_option :only, type: :array, default: nil,
    desc: "Only generate these components (#{VALID_COMPONENTS.join(', ')})"
  class_option :skip, type: :array, default: nil,
    desc: "Skip these components (#{VALID_COMPONENTS.join(', ')})"
```

- [ ] **Step 2: Add `validate_options!` and call it in `initialize`**

Modify `initialize` (line 51-55):

```ruby
  def initialize(*)
    super
    return unless behavior == :invoke
    validate_options!
    resolve_interactive_options if interactive?
  end
```

Add `validate_options!` in the `private` section (after line 121):

```ruby
  def validate_options!
    if options[:only]
      invalid = options[:only] - VALID_COMPONENTS
      if invalid.any?
        raise Thor::Error, "Invalid components for --only: #{invalid.join(', ')}. Valid: #{VALID_COMPONENTS.join(', ')}"
      end
    end

    if options[:skip]
      invalid = options[:skip] - VALID_COMPONENTS
      if invalid.any?
        raise Thor::Error, "Invalid components for --skip: #{invalid.join(', ')}. Valid: #{VALID_COMPONENTS.join(', ')}"
      end
    end
  end
```

- [ ] **Step 3: Add `component_enabled?` helper and guard each `create_*` method**

Add in the `private` section:

```ruby
  def component_enabled?(name)
    return false if options[:only] && !options[:only].include?(name)
    return false if options[:skip]&.include?(name)
    true
  end
```

Guard each `create_*` method with `return unless component_enabled?(...)`. The methods to guard and their component names:

```ruby
  def create_migration_file
    return unless component_enabled?(:migration)
    return if options[:skip_migration]
    template "migration.rb.tt", "db/migrate/#{timestamp}_create_#{table_name}.rb"
  end

  def create_application_record_file          # no guard — always needed if namespace is new
    return if namespace_base_classes_exist?
    template "application_record.rb.tt", "app/models/#{namespace_path}/application_record.rb"
  end

  def create_model_file
    return unless component_enabled?(:model)
    template "model.rb.tt", "app/models/#{model_file_path}.rb"
  end

  def create_application_controller_file      # no guard — always needed if namespace is new
    return if namespace_base_classes_exist?
    template "application_controller.rb.tt", "app/controllers/#{namespace_path}/application_controller.rb"
  end

  def create_controller_file
    return unless component_enabled?(:controller)
    template "controller.rb.tt", "app/controllers/#{controller_file_path}.rb"
  end

  def create_serializer_file
    return unless component_enabled?(:serializer)
    template "serializer.rb.tt", "app/serializers/#{serializer_file_path}.rb"
  end

  def create_policy_file
    return unless component_enabled?(:policy)
    template "policy.rb.tt", "app/policies/#{policy_file_path}.rb"
  end

  def create_fixture_file
    return unless component_enabled?(:fixture)
    return if options[:skip_tests]
    template "fixture.yml.tt", "test/fixtures/#{fixture_file_name}.yml"
  end

  def create_model_test_file
    return unless component_enabled?(:model_test)
    return if options[:skip_tests]
    template "model_test.rb.tt", "test/models/#{model_test_file_path}.rb"
  end

  def create_integration_test_file
    return unless component_enabled?(:integration_test)
    return if options[:skip_tests]
    template "integration_test.rb.tt", "test/integration/#{integration_test_file_path}.rb"
  end

  def add_route
    return unless component_enabled?(:route)
    return if options[:skip_routes]
    route "resources :#{plural_name}, except: %i[new edit]", namespace: namespace_path
  end

  def add_fixture_class_mapping               # no guard — always needed if tests are generated
    return if options[:skip_tests]
    return if fixture_class_already_mapped?
    ...
  end
```

Make each edit individually using `edit` tool.

- [ ] **Step 4: Verify with `--pretend`**

Run: `rails generate domain_module Events::Venue name:string --only controller serializer --no-interactive --pretend`

Expected output shows only controller + serializer created, nothing else.

Run: `rails generate domain_module Events::Venue name:string --skip migration model --no-interactive --pretend`

Expected output skips migration and model files.

Run: `rails generate domain_module Events::Venue name:string --only bogus --no-interactive --pretend`

Expected: `Thor::Error` with "Invalid components for --only: bogus"

- [ ] **Step 5: Commit**

```bash
git add lib/generators/domain_module/domain_module_generator.rb
git commit -m "feat(generator): add --only/--skip component selection"
```

### Task 2: Add sensitive attribute filter for ransackable attributes

**Files:**

- Modify: `lib/generators/domain_module/domain_module_generator.rb`

- [ ] **Step 1: Add `SENSITIVE_ATTRIBUTES` constant**

Add after the `VALID_COMPONENTS` constant (around line 42 in generator):

```ruby
  SENSITIVE_ATTRIBUTES = %w[
    password password_digest password_confirmation
    token api_key secret_key secret
    access_token refresh_token
    salt encrypted_password
    reset_password_token confirmation_token unlock_token
    authentication_token otp_secret_key
    private_key public_key
    ssn tin ein
  ].freeze
```

- [ ] **Step 2: Filter `ransackable_attributes_list`**

Modify `ransackable_attributes_list` (line 303-310):

```ruby
  def ransackable_attributes_list
    list = %w[id] +
      data_columns.reject { |c| c.type == :jsonb || sensitive_column?(c.name) }.map(&:name) +
      belongs_to_columns.map { |c| "#{c.name}_id" } +
      %w[slug created_at updated_at].tap { |l|
        l.delete("slug") unless slugable?
      }
    list
  end
```

- [ ] **Step 3: Add `sensitive_column?` helper**

Add in the `private` section:

```ruby
  def sensitive_column?(name)
    SENSITIVE_ATTRIBUTES.any? { |s| name.downcase.include?(s.downcase) }
  end
```

This checks both exact (`password`) and substring (`api_key_v2`) matches, case-insensitive.

- [ ] **Step 4: Verify with `--pretend`**

Run: `rails generate domain_module Events::Venue name:string api_key:string secret_token:string --no-interactive --pretend`

Read the generated model (from pretend's output or actual file) and verify `ransackable_attributes` does NOT include `api_key` or `secret_token`.

Run: `rails generate domain_module Ticketing::PaymentGateway api_key:string webhook_secret:string name:string --no-interactive --pretend`

Verify the model's ransackable list excludes `api_key` and `webhook_secret`.

- [ ] **Step 5: Run full test suite**

Run: `rails test`
Expected: all tests pass (existing tests don't use sensitive columns, so no change expected).

- [ ] **Step 6: Commit**

```bash
git add lib/generators/domain_module/domain_module_generator.rb
git commit -m "feat(generator): filter sensitive columns from ransackable attributes"
```

### Task 3: Update docs

**Files:**

- Modify: `docs/DOMAIN_MODULE_GENERATOR.md`

- [ ] **Step 1: Document `--only` / `--skip` in Options table**

Add rows to the options table:

```
| `--only one two` | (none) | Only generate listed components. Valid: migration, model, controller, serializer, policy, fixture, model_test, integration_test, route |
| `--skip one two` | (none) | Skip listed components. Valid: migration, model, controller, serializer, policy, fixture, model_test, integration_test, route |
```

- [ ] **Step 2: Document sensitive attribute filtering**

Add a subsection in "Generated Code Conventions":

```
### Sensitive attribute filtering

Columns matching sensitive patterns (password, token, secret, key, salt, etc.) are automatically excluded from the generated `ransackable_attributes` list. This prevents accidental exposure of secrets through the search API. Both exact and substring matches are checked case-insensitively (e.g., `api_key_v2` matches the `key` pattern).
```

- [ ] **Step 3: Commit**

```bash
git add docs/DOMAIN_MODULE_GENERATOR.md
git commit -m "docs(generator): document --only/--skip and sensitive attribute filter"
```
