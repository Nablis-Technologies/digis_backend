# PLATFORM NAMESPACE CODE REVIEW — ITERATION 4

**Date**: May 17, 2026
**Previous score**: 9.2/10
**New score**: 9.5/10

---

## WHAT YOU FIXED (ALL VERIFIED)

| # | Issue from Review 3 | Status | Notes |
|---|---------------------|--------|-------|
| 1 | `Common#set_clazz` fragile inference | ✅ FIXED | Replaced with explicit `self.model_class` declaration + clear error |

---

## THE FIX (VERIFIED)

**File**: `app/controllers/concerns/platform/common.rb:9,108-113`

```ruby
class_attribute :model_class, default: nil

def set_clazz
  @clazz = self.class.model_class
  return if @clazz.present?

  raise ArgumentError, "#{self.class.name} must declare self.model_class"
end
```

The old fragile inference (`controller_name.classify`, `deconstantize`, `safe_constantize`, fallback to `Core::`) is completely gone. Controllers must now explicitly declare:

```ruby
class Api::V1::EventsController < Core::ApplicationController
  self.model_class = Event
end
```

This is the correct pattern — **explicit over implicit**, no magic, no namespace guessing, no silent fallbacks. The error message is clear and actionable.

---

## WHAT'S STILL REMAINING

### 1. `# frozen_string_literal: true` Missing from 35 of 36 Files

Only `AuditableController` has it. Add to the top of every other Core file. Mechanical, one line per file.

**Priority**: Low effort, medium impact.

---

### 2. `Permission` Redundant Uniqueness Constraint

**File**: `app/models/platform/permission.rb:21`
```ruby
validates :resource, uniqueness: { scope: %i[action namespace], message: "..." }
```

Since `code` is auto-generated as `"#{resource}.#{action}"` with its own uniqueness constraint, this second validation is redundant. Adds an unnecessary DB query on every save.

**Fix**: Remove line 21.

**Priority**: Low. Works fine as-is, just wasteful.

---

### 3. Password Auth Still in Place (OTP Not Implemented)

**Files**: `UserAuthenticatable`, `AuthService`, `AuthController`

Still using `has_secure_password`. For Ethiopian market, phone-first OTP is the right approach.

**Priority**: Medium. Architectural shift. Do it before building the ticket purchase flow.

---

## FILE-BY-FILE GRADE CHANGES

| File | Previous | New | Change |
|------|----------|-----|--------|
| `concerns/platform/common.rb` | A- | **A+** | Explicit `model_class` declaration replaces fragile inference |

---

## SCORE BREAKDOWN

| Category | Previous | New | Notes |
|----------|----------|-----|-------|
| Security | 9.5/10 | **9.5/10** | No change |
| Code Quality | 9/10 | **9.5/10** | Explicit model_class eliminates magic inference |
| Architecture | 9.5/10 | **9.5/10** | No change |
| Market Fit | 3/10 | **3/10** | Still password auth |
| Maintainability | 8.5/10 | **9/10** | Explicit declarations are easier to reason about |
| **Overall** | **9.2/10** | **9.5/10** | **+0.3 point improvement** |

---

## REMAINING ACTION ITEMS

### Quick Wins (< 30 min total)

1. **Add `# frozen_string_literal: true` to 35 files** — mechanical
2. **Remove `Permission` redundant uniqueness constraint** — 1 line

### Big Lift (Before Ticket Purchase Flow)

3. **Replace password auth with OTP** — affects `UserAuthenticatable`, `AuthService`, `AuthController`, `User` model, migration

---

## SUMMARY

The `Common` concern is now bulletproof. No more namespace inference, no more fragile fallbacks. Controllers declare their model class explicitly, and get a clear error if they forget.

**Score: 9.5/10 — production-ready infrastructure. Only cosmetic and OTP items remain.**
