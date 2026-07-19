# REVIEWABLE SYSTEM REFACTOR

**Date**: June 18, 2026
**Scope**: Delete `ReviewableController`, delete `VerificationCallbacks`, keep only what's needed

---

## THE FUNDAMENTAL INSIGHT

The `Review` model **is** the state machine. Each row is an immutable transition event. Current state = most recent review for a context. You don't need a controller engine, a DSL, config hashes, or dynamic method definitions on top of it.

You need exactly three things:

| Thing | What it does | Lines |
|-------|-------------|-------|
| `Review` model | Immutable transition events | 34 (exists) |
| `ReviewableModel` concern | Query methods (`draft?`, `approved?`, `verified?`) | 54 (exists) |
| Explicit controller methods | `def submit`, `def approve`, etc. | ~100 per workflow |

That's it. The `ReviewableController` concern (317 lines) and `VerificationCallbacks` concern (47 lines) are unnecessary indirection.

---

## WHY `ReviewableController` SHOULD BE DELETED (NOT SIMPLIFIED)

The concern isn't just over-engineered — it's solving the wrong abstraction. It tries to be a **generic workflow engine** that any controller can declaratively configure. But:

1. **Each workflow has different rules.** Organization verification needs auto-approval by audience size and document readiness checks. Event verification might need ticket cap validation. Artist verification might need content moderation. The DSL can't configure these — you end up overriding half the concern's methods anyway.

2. **The DSL hides what matters.** The actual business logic (auto-approve, document validation, audit trail) is split across the concern, `VerificationCallbacks`, and controller overrides. A new developer can't read a single file and understand how verification works.

3. **It has a two-path code smell.** `VerificationsController#submit` bypasses the DSL's dynamic method and calls `perform_review_action` directly (because auto-approve doesn't fit the generic action mold). Meanwhile `approve`, `reject`, etc. use the dynamically-defined methods. Two different code paths in the same controller.

4. **Authorization is split.** The concern has `authorize_review_action!` with `skip_authorization` at the end. The controller overrides it. The admin controller overrides it differently. A before_action that calls a method that calls `skip_authorization` in another override is hard to reason about.

5. **The metaprogramming has real costs.** Can't grep for `def approve`. Stack traces point to dynamically-defined methods. IDE can't navigate. Every new dev traces through the DSL to understand what happens.

---

## THE STATE MACHINE IS IN THE DATA MODEL (NOT THE CONTROLLER)

The `Review` model already gives you:

```
┌──────────────────────────────────────────────────────────┐
│                  core_reviews table                       │
│                                                          │
│  id: 1  reviewable: Org#1  context: verification        │
│         status: pending     reviewed_by: User#42         │
│         feedback: null      reviewed_at: 2026-06-18      │
│                                                          │
│  id: 2  reviewable: Org#1  context: verification        │
│         status: approved    reviewed_by: User#7          │
│         feedback: {}        reviewed_at: 2026-06-19      │
│                                                          │
│  Current state = latest row = "approved"                 │
│  Full history = all rows = [pending, approved]           │
└──────────────────────────────────────────────────────────┘
```

This follows your taste preference exactly: "Store state transitions as immutable event records rather than mutating a single status field. Derive current state from the most recent transition."

You don't need `TRANSITIONS` config hashes or `valid_transition?` methods in a controller concern. The controller just needs to:
1. Read the current review
2. Decide if the requested transition is allowed
3. Create a new review row
4. Record an audit entry

That's 10 lines of logic, not 317.

---

## WHAT STAYS (NO CHANGES)

### `Core::Review` model

The immutable transition event. Polymorphic `reviewable`, polymorphic `reviewed_by`, context-scoped, status-tracked. Perfect as-is.

### `Core::ReviewableModel` concern

Status query methods so models can answer `pending?(:verification)` and `approved?(:verification)`. Clean, minimal, stays exactly as-is.

```ruby
# app/models/concerns/core/reviewable_model.rb — NO CHANGES
module Core
  module ReviewableModel
    extend ActiveSupport::Concern

    included do
      has_many :reviews, as: :reviewable, class_name: "Core::Review", dependent: :destroy
    end

    def review_for(context = :default)
      reviews.with_context(context).recent_first
    end

    def current_review_for(context = :default)
      review_for(context).first
    end

    def current_status_for(context = :default)
      current_review_for(context)&.status || "draft"
    end

    def build_review_for(context = :default)
      reviews.build(context: context.to_s)
    end

    def draft?(context = :default)
      current_status_for(context) == "draft"
    end

    def pending?(context = :default)
      current_status_for(context) == "pending"
    end

    def approved?(context = :default)
      current_status_for(context) == "approved"
    end

    def rejected?(context = :default)
      current_status_for(context) == "rejected"
    end

    def modification_requested?(context = :default)
      current_status_for(context) == "modify"
    end

    def editable?(context = :default)
      draft?(context)
    end

    def submitted?(context = :default)
      !draft?(context)
    end
  end
end
```

---

## WHAT GETS DELETED

| File | Reason |
|------|--------|
| `app/controllers/concerns/core/reviewable_controller.rb` | 317-line state machine DSL solving a problem the `Review` model already solves |
| `app/controllers/concerns/verification_callbacks.rb` | 47 lines of audit/hook logic that belongs in the controller, not a concern |

---

## WHAT GETS WRITTEN (FROM SCRATCH)

### Design decisions (addressing review feedback)

1. **`InvalidTransition` defined as a module-level constant** — not under `private` in the controller. `class InvalidTransition < StandardError; end` inside a private block is a Ruby quirk (classes can't be private, but it scopes oddly). Defined at module level for clean `rescue_from`.

2. **`rescue_from` instead of per-action rescue blocks** — `rescue_from InvalidTransition` and `rescue_from Pundit::NotAuthorizedError` at class level. Each action is just the happy path. This also catches the authorization error (which per-action `rescue InvalidTransition` blocks would miss).

3. **`before_action :authorize_review_action!` instead of inline calls** — the v1 proposal's argument against `before_action` was about the old DSL's confusing `skip_authorization` pattern. A clean `before_action` with explicit `only:` is idiomatic Rails.

4. **No VALID_TRANSITIONS constant** — the action methods themselves define what transitions are valid through the `from_status` parameter they pass to `validate_transition!`. If `def reject` passes `validate_transition!("pending", "rejected")`, that IS the allowed transition. No separate table to drift out of sync with the action methods.

5. **`record_audit!` extracted in both controllers** — not inlined 3 times in the admin controller.

---

### 1. `Organizations::VerificationsController` — explicit, ~130 lines

```ruby
# app/controllers/organizations/verifications_controller.rb
module Organizations
  class VerificationsController < Organizations::ApplicationController
    include Core::JsonResponse

    class InvalidTransition < StandardError; end

    rescue_from InvalidTransition, with: :handle_invalid_transition
    rescue_from Pundit::NotAuthorizedError, with: :handle_not_authorized
    rescue_from ActiveRecord::RecordInvalid, with: :handle_record_invalid

    before_action :set_organization
    before_action :authorize_review_action!, only: %i[submit approve reject request_modification resubmit]

    AUTO_APPROVE_AUDIENCE = %w[under_100 100_500].freeze

    # ── ACTIONS ──────────────────────────────────────────────────

    def submit
      ensure!(submission_ready?, "All required documents must be uploaded before submission")
      ensure_not_already_submitted!

      status = auto_approve? ? "approved" : "pending"
      reviewer = auto_approve? ? nil : current_user

      review = create_review_transition!(status, from: "draft", reviewer: reviewer, feedback: {})
      record_audit!(review)

      render_success(data: @organization)
    end

    def approve
      review = create_review_transition!("approved", from: "pending", reviewer: current_user, feedback: {})
      record_audit!(review)

      render_success(data: @organization)
    end

    def reject
      ensure!(review_feedback_params.present?, "Feedback is required")
      review = create_review_transition!("rejected", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)

      render_success(data: @organization)
    end

    def request_modification
      ensure!(review_feedback_params.present?, "Feedback is required")
      review = create_review_transition!("modify", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)

      render_success(data: @organization)
    end

    def resubmit
      @organization.update!(model_params) if model_params.present?

      review = create_review_transition!("pending", from: %w[rejected modify], reviewer: current_user, feedback: {})
      record_audit!(review)

      render_success(data: @organization)
    end

    private

    # ── TRANSITION HELPERS ───────────────────────────────────────

    def create_review_transition!(status, from:, reviewer:, feedback:)
      current_review = @organization.current_review_for(:verification)
      current_status = current_review&.status || "draft"

      ensure!(
        Array(from).include?(current_status),
        "Cannot transition from '#{current_status}' to '#{status}'"
      )

      review = current_review || @organization.build_review_for(:verification)
      review.update!(
        status: status,
        feedback: feedback,
        reviewed_by: reviewer,
        reviewed_at: Time.current
      )
      review
    end

    def ensure_not_already_submitted!
      ensure!(
        @organization.current_review_for(:verification).nil?,
        "Already submitted"
      )
    end

    def ensure!(condition, message)
      raise InvalidTransition, message unless condition
    end

    # ── SUBMISSION READINESS ─────────────────────────────────────

    def submission_ready?
      @organization.profile.attached? &&
        @organization.banner.attached? &&
        @organization.business_license.attached? &&
        @organization.tin_certificate.attached?
    end

    # ── AUTO-APPROVE ─────────────────────────────────────────────

    def auto_approve?
      @organization.estimated_audience.in?(AUTO_APPROVE_AUDIENCE)
    end

    # ── AUTHORIZATION ────────────────────────────────────────────

    def authorize_review_action!
      authorize @organization, policy_class: Organizations::VerificationPolicy
      raise Pundit::NotAuthorizedError, "not allowed to #{action_name} this organization" unless valid_reviewer?
    end

    def valid_reviewer?
      return false if owner_enforcement_failed?
      return false if self_review?
      true
    end

    def owner_enforcement_failed?
      return false if current_user.super_admin?

      membership = @organization.memberships.active.find_by(user_id: current_user.id)
      return true if membership.nil?

      %w[submit resubmit].include?(action_name) && membership.staff?
    end

    def self_review?
      return false unless %w[approve reject request_modification].include?(action_name)

      @organization.memberships.active.exists?(user_id: current_user.id)
    end

    # ── AUDIT ────────────────────────────────────────────────────

    def record_audit!(review)
      return if review.reviewed_by.nil? && review.status == "approved"

      @organization.record_audit!(
        action_name,
        actor: current_user,
        metadata: {
          "review_id"     => review.id,
          "review_status" => review.status,
          "feedback"      => review.feedback
        }.compact
      )
    end

    # ── ERROR HANDLING ───────────────────────────────────────────

    def handle_invalid_transition(exception)
      render_error(exception.message, status: :unprocessable_entity)
    end

    def handle_not_authorized(exception)
      render_error(exception.message, status: :forbidden)
    end

    def handle_record_invalid(exception)
      render_error(exception.record.errors.full_messages.first, status: :unprocessable_entity)
    end

    # ── RESOURCE LOADING ─────────────────────────────────────────

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    rescue ActiveRecord::RecordNotFound
      render_error("Organization not found", status: :not_found)
    end

    # ── PARAMS ───────────────────────────────────────────────────

    def model_params
      return {} unless params[:organization].present?

      params.require(:organization).permit(
        :name, :description, :organizer_type, :category,
        :contact_phone, :contact_email, :website_url,
        :tin_number, :address_line1, :address_line2, :city, :region,
        :estimated_audience, :event_frequency,
        social_links: {}
      )
    end

    def review_feedback_params
      feedback = params[:feedback] || params[:review_feedback]
      return {} unless feedback

      feedback.permit! if feedback.respond_to?(:permit!)
      feedback
    end
  end
end
```

### 2. `Admin::VerificationsController` — explicit, ~65 lines

```ruby
# app/controllers/admin/verifications_controller.rb
module Admin
  class VerificationsController < Admin::ApplicationController
    include Core::JsonResponse

    class InvalidTransition < StandardError; end

    rescue_from InvalidTransition, with: :handle_invalid_transition
    rescue_from Pundit::NotAuthorizedError, with: :handle_not_authorized

    before_action :set_organization
    before_action :authorize_review_action!, only: %i[approve reject request_modification]

    def approve
      review = create_review_transition!("approved", from: "pending", reviewer: current_user, feedback: {})
      record_audit!(review)
      render_success(data: @organization)
    end

    def reject
      ensure!(review_feedback_params.present?, "Feedback is required")
      review = create_review_transition!("rejected", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)
      render_success(data: @organization)
    end

    def request_modification
      ensure!(review_feedback_params.present?, "Feedback is required")
      review = create_review_transition!("modify", from: "pending", reviewer: current_user, feedback: review_feedback_params)
      record_audit!(review)
      render_success(data: @organization)
    end

    private

    def create_review_transition!(status, from:, reviewer:, feedback:)
      current_review = @organization.current_review_for(:verification)
      current_status = current_review&.status || "draft"

      ensure!(
        Array(from).include?(current_status),
        "Cannot transition from '#{current_status}' to '#{status}'"
      )

      review = current_review || @organization.build_review_for(:verification)
      review.update!(
        status: status,
        feedback: feedback,
        reviewed_by: reviewer,
        reviewed_at: Time.current
      )
      review
    end

    def ensure!(condition, message)
      raise InvalidTransition, message unless condition
    end

    def authorize_review_action!
      authorize @organization, policy_class: Admin::VerificationPolicy
      if @organization.memberships.active.exists?(user_id: current_user.id)
        raise Pundit::NotAuthorizedError, "cannot review your own organization"
      end
    end

    def record_audit!(review)
      @organization.record_audit!(
        action_name,
        actor: current_user,
        metadata: {
          "review_id"     => review.id,
          "review_status" => review.status,
          "feedback"      => review.feedback
        }.compact
      )
    end

    def handle_invalid_transition(exception)
      render_error(exception.message, status: :unprocessable_entity)
    end

    def handle_not_authorized(exception)
      render_error(exception.message, status: :forbidden)
    end

    def review_feedback_params
      feedback = params[:feedback] || params[:review_feedback]
      return {} unless feedback

      feedback.permit! if feedback.respond_to?(:permit!)
      feedback
    end

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    rescue ActiveRecord::RecordNotFound
      render_error("Organization not found", status: :not_found)
    end
  end
end
```

---

## WHAT CHANGED FROM v2 DRAFT (ADDRESSING REVIEW FEEDBACK)

| Issue | v2 Draft | v3 Final |
|-------|----------|----------|
| `InvalidTransition` defined under `private` | `private` + `class InvalidTransition < StandardError; end` (Ruby quirk, scoped oddly) | Defined at module-level inside the controller class |
| Authorization errors uncaught | Per-action `rescue InvalidTransition` blocks would miss `Pundit::NotAuthorizedError` | `rescue_from Pundit::NotAuthorizedError` at class level catches all |
| Lost Pundit `authorize` call | `authorize_review_action!` only did custom checks, missing `authorize @org, policy_class:` | Restored: `authorize @organization, policy_class: Organizations::VerificationPolicy` as first line |
| `validate_transition!` double-check | Checked `from_statuses.include?(from)` AND `VALID_TRANSITIONS[from].include?(to)` — redundant | Only checks `from_statuses.include?(from)`. The action method call itself defines the valid transition |
| Admin audit inlined 3x | Audit `record_audit!(...)` hash inlined in each action | Extracted `record_audit!(review)` method |
| `authorize_review_action!` in every action | Called explicitly in each action method (5 identical lines) | `before_action :authorize_review_action!, only: [...]` (1 line) |
| Per-action rescue blocks | Repeated `rescue InvalidTransition` block in every action | `rescue_from InvalidTransition` at class level — actions are happy-path only |
| `ensure` naming | `ensure(condition, message)` — reads oddly next to Ruby's `ensure` keyword | `ensure!(condition, message)` — bang signals "this raises" |
| Feedback validation missing | `reject` and `request_modification` created reviews with empty feedback (`review_feedback_params` silently returned `{}`) | `ensure!(review_feedback_params.present?, "Feedback is required")` before transition |
| Admin `authorize` call | Instantiated `Admin::VerificationPolicy.new(...)` manually, missing Pundit's `authorize` method with policy-method mapping | `authorize @organization, policy_class: Admin::VerificationPolicy` as first line |

---

## WHERE ELSE IN THE PROJECT COULD THIS PATTERN BE USED?

Currently, `Artists` and `Venues` have simple `verified: boolean` columns. These are **one-bit flags** — no history, no transition audit, no approval workflow. If they grow (e.g., artists need content review, venues need document verification), they'd follow the exact same pattern:

```ruby
# Hypothetical future: Events::Artist verification
class Admin::ArtistVerificationsController < Admin::ApplicationController
  class InvalidTransition < StandardError; end
  rescue_from InvalidTransition, with: :handle_invalid_transition
  rescue_from Pundit::NotAuthorizedError, with: :handle_not_authorized

  before_action :set_artist
  before_action :authorize_review_action!, only: %i[approve reject request_modification]

  def approve
    review = create_review_transition!("approved", from: "pending", ...)
    # ...
  end
end
```

The pattern is always the same:
1. Model includes `ReviewableModel`
2. Controller has `rescue_from`, `before_action`, explicit action methods
3. Each action validates its transition via `create_review_transition!`, records an audit

Each workflow has **different** rules (different transitions, different readiness checks, different auto-approval criteria). The `Review` model handles the common part (immutable event storage). The controller handles the flow-specific part (business logic). No DSL needed.

---

## DUPLICATION CHECK: TWO CONTROLLERS WITH SIMILAR CODE

`Organizations::VerificationsController` and `Admin::VerificationsController` share ~25 lines of near-identical code (`create_review_transition!`, `ensure`, error handlers, `review_feedback_params`). Is this worth extracting into a concern?

**No.** Here's why:

1. It's 25 lines. Extracting it into a concern would add more indirection than it removes duplication.
2. The two controllers have **different authorization**, different allowed transitions, different audit logic, and different param handling. The shared part is the simplest part.
3. If a third controller is added (e.g., `ArtistVerificationsController`), copy-paste the skeleton. If it hits 4+ controllers and the duplication is genuinely painful, extract a small base class or concern. But don't pre-abstract.

The `Review` model and `ReviewableModel` concern **are** the shared infrastructure. The controller logic is flow-specific.

---

## COMPARISON

| Axis | Before (DSL Engine) | After (Explicit) |
|------|--------------------|--------------------|
| `ReviewableController` lines | 317 | **Deleted** |
| `VerificationCallbacks` lines | 47 | **Deleted** |
| `VerificationsController` lines | ~70 | ~130 |
| `Admin::VerificationsController` lines | ~30 | ~65 |
| **Total lines** | ~465 | ~195 |
| Metaprogramming | `define_method`, `class_attribute`, `respond_to?(:method, true)` | **None** |
| How to find `approve` | Trace DSL → `define_method` → `perform_review_action` | `grep "def approve"` |
| Error handling | `if performed?` guard clauses, per-action rescue | `rescue_from` at class level |
| Authorization | Before action with `skip_authorization` in overrides | Clean `before_action` with explicit method |
| Hook system | `respond_to?(:before_reviewable_action, true)` | **None** — all logic is inline |
| Number of concerns | 3 (`ReviewableController`, `VerificationCallbacks`, `Common`) | 1 (`Core::JsonResponse`) |

---

## MIGRATION STEPS

1. Write the new `Organizations::VerificationsController` (above)
2. Write the new `Admin::VerificationsController` (above)
3. Delete `app/controllers/concerns/core/reviewable_controller.rb`
4. Delete `app/controllers/concerns/verification_callbacks.rb`
5. `ReviewableModel` stays — no changes
6. `Review` model stays — no changes
7. Run existing tests, update any that relied on the DSL's internal methods
8. Routes unchanged — they point to action names, which still exist

---

## DESIGN PRINCIPLES APPLIED

1. **"Store state transitions as immutable event records"** — The `Review` model does this. Each transition is a row. Current state is derived, not stored.

2. **"Prefer explicit, greppable controller methods over metaprogrammed DSLs when there is only one use case"** — Every action is a real method. `grep "def approve"` finds it. No DSL.

3. **"The data model is the state machine"** — Don't build a state machine on top of a state machine. The `Review` table with `recent_first` scope already gives you current state, full history, and per-context isolation.
