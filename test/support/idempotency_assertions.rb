# frozen_string_literal: true

# Reusable idempotency assertions for operations whose side effects must be
# stable under replay (retries, double-submits, at-least-once job delivery).
#
# The classic bug this catches: an operation claims to be idempotent (e.g. via
# a unique "idempotency key") but its key is non-deterministic, so a replay
# silently duplicates the side effect instead of collapsing onto it. A
# happy-path test that runs the operation once never exercises the replay path,
# which is exactly why this class of defect slips through.
module IdempotencyAssertions
  # `subject` - a callable performing the operation (invoked repeatedly).
  # `counter` - a callable returning an integer measure of the persistent side
  #             effect (e.g. the number of audit rows for an action).
  #
  # The first run must have an effect, and every identical replay must leave
  # that measure unchanged.
  def assert_idempotent(subject, counter:)
    baseline = counter.call
    subject.call
    first = counter.call

    assert_operator first, :>, baseline,
      "operation had no observable persistent effect; nothing to assert idempotency against"

    subject.call
    second = counter.call
    assert_equal first, second,
      "replaying an identical operation changed its persistent effect " \
      "(#{first} -> #{second}); the operation is not idempotent"
  end

  # Audit-system helper: asserts replaying `subject` does not create duplicate
  # Core::AuditLog rows for the same action/resource. `auditable_id` may be a
  # value or a callable (so it can be resolved after `subject` creates the row).
  def assert_audit_idempotent(subject, action:, auditable_type:, auditable_id:)
    resolve_id = auditable_id.respond_to?(:call) ? auditable_id : -> { auditable_id }
    counter = lambda do
      Core::AuditLog.where(action:, auditable_type:, auditable_id: resolve_id.call).count
    end
    assert_idempotent(subject, counter:)
  end
end

ActiveSupport::TestCase.include(IdempotencyAssertions)
