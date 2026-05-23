# I18n Message Localization for API Responses

**Date:** 2026-05-23
**Status:** Implemented — 2026-05-23

## Overview

Move all hardcoded API response messages into `config/locales/en.yml` and switch controllers to use I18n symbol keys or auto-inference. Centralizes message management, enables future localization, and cleans up controller code.

## Current state

The infrastructure exists but is unused:

- `Core::JsonResponse#resolve_message` already accepts symbols (translates via `I18n.t`) and auto-infers keys from model + action
- `Core::JsonResponse#inferred_message_key` generates keys like `category.success.show`, `user.errors.login`
- All controller call sites pass raw strings instead

## Locale key structure

### Auto-inferred keys (CRUD actions via `Core::Common`)

`render_success` / `render_error` with no message argument auto-resolve:

```
en:
  category:
    success:
      index: "Categories retrieved successfully"
      show: "Category retrieved successfully"
      create: "Category created successfully"
      update: "Category updated successfully"
      destroy: "Category deleted successfully"
    errors:
      create: "Failed to create category"
      update: "Failed to update category"
      destroy: "Failed to delete category"
```

### Explicit keys (scoped symbols for controllers without `@clazz`)

Controllers like `AuthController` that don't include `Core::Common` need explicit keys. Pass them as **scoped symbols** — `I18n.t(:"auth.success.login")` resolves nested YAML keys correctly:

```yaml
en:
  auth:
    success:
      login: "Logged in successfully"
      signup: "Account created successfully"
      refresh: "Token refreshed successfully"
      logout: "Logged out successfully"
      me: "User retrieved successfully"
    errors:
      invalid_credentials: "Invalid credentials"
      invalid_token: "Invalid token"
      signup: "Failed to create account"
      refresh: "Failed to refresh token"
```

Controllers use them as:
```ruby
render_success(:"auth.success.logout")
render_error(:"auth.errors.invalid_credentials", status: :unauthorized)
```

The colon-prefixed symbol with dots (`:"auth.success.logout"`) is a Ruby scoped symbol — `I18n.t` resolves it through the nested YAML tree.

### Authorization errors

```yaml
en:
  authorization:
    errors:
      unauthorized: "You are not authorized to perform this action"
```

Used as:
```ruby
render_error(:"authorization.errors.unauthorized", status: :forbidden, code: "not_authorized")
```

### Reviewable workflow keys (dynamic params via interpolation)

```
en:
  review:
    errors:
      undefined_action: "Action '%{action}' is not defined for context '%{context}'"
      invalid_transition: "Cannot transition from '%{from}' to '%{to}'"
      feedback_required: "Feedback is required for %{status}"
      submission_not_ready: "Resource must be complete before submission"
      not_authorized: "You are not authorized to perform this action"
      config_error: "Reviewable configuration error: %{message}"
    success:
      transition: "Status updated successfully"
```

## Changes

### 1. `config/locales/en.yml`

Add all keys under the structure above.

### 2. `app/controllers/core/auth_controller.rb`

Replace hardcoded strings with scoped symbol keys:

```ruby
# Before:
render_error("Invalid credentials", status: :unauthorized, code: "invalid_credentials")
render_success("Logout successful")

# After:
render_error(:"auth.errors.invalid_credentials", status: :unauthorized, code: "invalid_credentials")
render_success(:"auth.success.logout")
```

Scoped symbols (`:"auth.success.logout"`) work because `resolve_message` passes them to `I18n.t`, which resolves dot-separated keys through the YAML tree.

### 3. `app/controllers/concerns/core/authorizable.rb`

Replace hardcoded string:

```ruby
# Before:
render_error("You are not authorized to perform this action", status: :forbidden, code: "not_authorized")

# After:
render_error(:not_authorized, status: :forbidden, code: "not_authorized")
```

### 4. `app/controllers/concerns/core/authenticatable.rb`

This one uses `error.message` from exception objects — no change needed. The error classes carry their own messages.

### 5. `app/controllers/concerns/core/reviewable_controller.rb`

Replace hardcoded strings with I18n interpolation:

```ruby
# Before:
render_error("Action '#{action_name}' is not defined for context '#{current_review_context}'", status: :bad_request)

# After:
render_error(I18n.t("review.errors.undefined_action", action: action_name, context: current_review_context), status: :bad_request)
```

These use `I18n.t` directly since they need dynamic interpolation. The `resolve_message` method only handles simple symbols and auto-inference, not interpolation — so direct `I18n.t` at the call site is appropriate for messages with dynamic values.

### 6. No changes to `Core::Common` CRUD actions

The CRUD actions in `common.rb` (index, show, create, update, destroy) already call `render_success` / `render_error` without a message argument. Once locale keys exist under `category.success.index` etc., auto-inference kicks in and messages appear automatically. No code changes needed.

### 7. `render_success` / `render_error` message behavior

| Scenario | Example | Resolution |
|----------|---------|------------|
| No message, model has locale key | `render_success` | Auto-inferred: `category.success.show` |
| No message, no locale key | `render_success` | No `message` in response (current behavior) |
| Symbol, key exists | `render_success(:hello)` | `I18n.t(:hello)` |
| Symbol, key missing | `render_success(:unknown)` | Falls back to `"unknown"` string |
| String | `render_success("Done")` | Passed through as-is |
| Dynamic interpolation | `render_success(I18n.t("key", arg: val))` | Evaluated at call site |

## Rollout

1. Add all locale keys to `config/locales/en.yml`
2. Update `auth_controller.rb` to use symbols
3. Update `authorizable.rb` to use symbol
4. Update `reviewable_controller.rb` to use `I18n.t` with interpolation
5. Remove the `hello: "Hello world"` default key
6. Run full test suite
7. Verify with rails runner that auto-inference works for categories
