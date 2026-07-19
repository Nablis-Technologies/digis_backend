# serializer_profile Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `serializer_fields` + `default_serializer_includes` with a single `serializer_profile` method on controllers.

**Architecture:** A single `serializer_profile` hash on the controller returns per-action `{ fields:, include: }` config. `Core::JsonResponse` reads `fields` for attribute visibility (intersected with policy). `Core::Common#serializer_includes_for_action` reads `include` for AMS associations. Both respect a `default` key for shared config with whole-key override.

**Tech Stack:** Ruby 3.4, Rails 8.0, ActiveModelSerializers, Pundit

---

### Task 1: Update `Core::JsonResponse` — replace `serializer_fields` with `serializer_profile`

**Files:**
- Modify: `app/controllers/concerns/core/json_response.rb`

- [ ] **Step 1: Remove `serializer_fields` and add `serializer_profile` default**

  Replace:
  ```ruby
  def serializer_fields
    nil
  end
  ```

  With:
  ```ruby
  def serializer_profile
    {}
  end
  ```

- [ ] **Step 2: Update `resolved_visible_attributes` to read from `serializer_profile`**

  Replace:
  ```ruby
  def resolved_visible_attributes(data)
    controller_fields = serializer_fields&.dig(action_name.to_sym)
    policy_fields = policy_visible_attributes_for(data)

    return nil if controller_fields.nil? && policy_fields.nil?
    return controller_fields.map(&:to_sym) if policy_fields.nil?
    return policy_fields.map(&:to_sym) if controller_fields.nil?

    controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
  end
  ```

  With:
  ```ruby
  def resolved_visible_attributes(data)
    profile = serializer_profile
    action_sym = action_name.to_sym
    action_config = profile[action_sym] || {}
    default_conf = profile[:default] || {}
    controller_fields = action_config.key?(:fields) ? action_config[:fields] : default_conf[:fields]
    policy_fields = policy_visible_attributes_for(data)

    return nil if controller_fields.nil? && policy_fields.nil?
    return controller_fields.map(&:to_sym) if policy_fields.nil?
    return policy_fields.map(&:to_sym) if controller_fields.nil?

    controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
  end
  ```

### Task 2: Update `Core::Common` — remove `default_serializer_includes`, update `serializer_includes_for_action`

**Files:**
- Modify: `app/controllers/concerns/core/common.rb`

- [ ] **Step 1: Remove `default_serializer_includes` method**

  Delete these lines (150-152):
  ```ruby
  def default_serializer_includes
    {}
  end
  ```

- [ ] **Step 2: Replace `serializer_includes_for_action` body**

  Replace:
  ```ruby
  def serializer_includes_for_action(action)
    includes = default_serializer_includes
    return includes if includes.is_a?(Array)
    return [] unless includes.is_a?(Hash)

    includes[action] || includes[:default] || []
  end
  ```

  With:
  ```ruby
  def serializer_includes_for_action(action)
    profile = serializer_profile
    action_sym = action.to_sym
    action_config = profile[action_sym] || {}
    default_conf = profile[:default] || {}
    action_config.key?(:include) ? action_config[:include] : default_conf[:include] || []
  end
  ```

### Task 3: Update `CategoriesController` — use `serializer_profile`

**Files:**
- Modify: `app/controllers/events/categories_controller.rb`

- [ ] **Step 1: Replace `serializer_fields` + `default_serializer_includes` with `serializer_profile`**

  Remove:
  ```ruby
  def serializer_fields
    {
      index:  %i[id name slug],
      show:   %i[id name description slug metadata active created_at updated_at],
      create: %i[id name slug],
      update: %i[id name slug]
    }
  end

  def default_serializer_includes
    {
      index: [],
      show: [],
      create: [],
      update: []
    }
  end
  ```

  Add:
  ```ruby
  def serializer_profile
    {
      index: {
        fields: %i[id name slug]
      },
      show: {
        fields: %i[id name description slug metadata active created_at updated_at]
      },
      create: {
        fields: %i[id name slug]
      },
      update: {
        fields: %i[id name slug]
      }
    }
  end
  ```

- [ ] **Step 2: Run tests to verify everything works so far**

  Run: `rails test`
  Expected: 77 runs, 0 failures

### Task 4: Update `Core::ResourceTest` — detect fields from `serializer_profile` with default inheritance

**Files:**
- Modify: `test/support/core/resource_test.rb`

- [ ] **Step 1: Replace `serializer_fields` detection with profile-based detection**

  Find `resolve_default_check_attributes` and replace the entire method:

  ```ruby
  def resolve_default_check_attributes
    return if @options.key?(:check_attributes)

    profile = @controller_class&.new&.send(:serializer_profile) rescue nil
    return resolve_default_check_attributes_from_columns if profile.blank?

    default_fields = profile[:default]&.dig(:fields)
    full_set = resolve_serializer_attribute_names
    action_fields = @actions.each_with_object({}) do |action, hash|
      action_config = profile[action]
      if action_config&.key?(:fields)
        hash[action] = action_config[:fields]
      elsif default_fields
        hash[action] = default_fields
      end
    end

    action_fields.each do |action, attrs|
      next if attrs.nil?
      attr_strings = attrs.map(&:to_s)
      @check_attributes[action] ||= attr_strings
      absent = full_set - attr_strings
      @check_attributes[:"#{action}_absent"] ||= absent if absent.any?
    end
  end

  def resolve_default_check_attributes_from_columns
    columns = @model_class.column_names - %w[id created_at updated_at] rescue []
    @check_attributes[:show] ||= columns if columns.any?
    @check_attributes[:index] ||= columns if columns.any?
  end
  ```

- [ ] **Step 2: Run tests to verify**

  Run: `rails test`
  Expected: 77 runs, 0 failures

### Task 5: Update docs

**Files:**
- Modify: `docs/TEST_HELPERS_GUIDE.md`
- Modify: `docs/JSON_RESPONSE_MODULE_DOCUMENTATION.md`
- Modify: `docs/platform/api-responses-and-serialization.md`
- Modify: `docs/COMMON_MODULE_DOCUMENTATION.md`
- Modify: `docs/AUTHORIZABLE_MODULE_DOCUMENTATION.md`
- Modify: `docs/platform/authentication-and-rbac.md`

- [ ] **Step 1: Update `docs/TEST_HELPERS_GUIDE.md`**

  Replace all references to `serializer_fields` with `serializer_profile`:

  - Auto-detection table (lines ~126-128): change to `serializer_profile[action][:fields]`
  - Attribute visibility override examples (lines ~229-260): update declarations to `serializer_profile` multi-line format
  - "How it works" section (line ~323): replace `serializer_fields` example with `serializer_profile`
  - Pipeline diagram (line ~392): update to read from `serializer_profile`
  - Files involved table (line ~407-408): replace references
  - Step-by-step guide (line ~416): replace `serializer_fields` with `serializer_profile`

- [ ] **Step 2: Update `docs/JSON_RESPONSE_MODULE_DOCUMENTATION.md`**

  In the "Action-Specific Attribute Visibility" section (around line 240):
  - Replace `def serializer_fields` with `def serializer_profile` in the multi-line format
  - Update the description to mention `default` key inheritance
  - Remove the `def default_serializer_includes` example (line ~229)

- [ ] **Step 3: Update `docs/platform/api-responses-and-serialization.md`**

  In "Attribute Visibility Pipeline" section (around line 63):
  - Update `controller.serializer_fields[action]` to `controller.serializer_profile.dig(action, :fields)` in the pipeline diagram
  - Replace `### Controller layer (serializer_fields)` example with `serializer_profile` multi-line format
  - Update line about associations: remove reference to `default_serializer_includes`, say "remain controlled by `serializer_profile[action][:include]`"

- [ ] **Step 4: Update `docs/COMMON_MODULE_DOCUMENTATION.md`**

  Replace the two separate sections:
  - `### default_serializer_includes (Optional)` (line ~232)
  - `### serializer_fields (Optional)` (line ~247)

  With a single section:

  ```markdown
  ### `serializer_profile` (Optional)

  Defines which attributes and associations to expose per action. Returns a hash with action symbols as keys, plus an optional `default` key for shared config.

  ```ruby
  def serializer_profile
    {
      default: {
        fields: %i[id name slug],
        include: [:ticket_types]
      },
      show: {
        fields: %i[id name description slug metadata active created_at updated_at],
        include: [:venue]
      }
    }
  end
  ```

  Resolution rules:
  - `default` is inherited by all actions unless overridden per-action.
  - Override is whole-key — if an action has `fields:`, it replaces `default`'s `fields` entirely.
  - `fields:` controls which resource attributes appear (requires `Core::AttributeVisibilitySerializer` in the serializer).
  - `include:` controls which associated resources are side-loaded via AMS.
  ```

  Also update the best practices (lines ~322-323):
  Replace #6 and #7 with a single item:
  ```
  6. **Use `serializer_profile`** — Controls which attributes and associations are returned per action in a single declaration.
  ```

- [ ] **Step 5: Update `docs/AUTHORIZABLE_MODULE_DOCUMENTATION.md`**

  In the "Per-Role Attribute Visibility" section (around line 218):
  - Change `controller.serializer_fields[action]` to `controller.serializer_profile[action][:fields]` in the resolver description
  - Change the example controller code from `serializer_fields` to `serializer_profile`
  - Update "associations remain managed by default_serializer_includes" to "associations remain managed by serializer_profile[action][:include]"

- [ ] **Step 6: Update `docs/platform/authentication-and-rbac.md`**

  In the "Per-Role Attribute Visibility" table (line ~56):
  - Change `controller.serializer_fields` to `controller.serializer_profile[:fields]`

- [ ] **Step 7: Run full test suite**

  Run: `rails test`
  Expected: 77 runs, 0 failures

### Task 6: Final verification

- [ ] **Step 1: Run full test suite one last time**

  Run: `rails test`
  Expected: 77 runs, 0 failures

- [ ] **Step 2: Quick smoke test — verify serializer_profile is properly private and consumed**

  Run: `rails runner 'puts Events::CategoriesController.new.send(:serializer_profile).inspect'`
  Expected: Prints the full profile hash with index/show/create/update keys
