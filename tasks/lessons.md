# Lessons

- When a user asks to finish a plan, reconcile the canonical plan checkboxes with the actual committed code before advancing; distinguish completed implementation from remaining gated tasks and update the plan as each tranche is verified.

- For pre-launch invitation delivery, use the hybrid boundary: persist the
  one-time token encrypted alongside its lookup digest, publish only the
  invitation ID through the outbox, and let a provider-injection job decrypt
  and delegate delivery. Do not build a mail/SMS adapter before Messaging owns
  that integration.

- When verifying a merge, fetch the remote branch before comparing local
  tracking refs. A stale local `origin/main` ref caused the merged `main`
  commit to be reported as missing even though GitHub already had it.

- New domain services, models, and API controllers need concise comments that
  explain their responsibility and non-obvious invariants (privacy, retention,
  idempotency, immutability, or authorization boundaries). Avoid restating
  obvious code; add method comments only where the implementation rationale is
  not self-evident.

- Before starting a planned task, use the approved canonical plan under
  `docs/superpowers/plans/` as the specification. Do not create a duplicate
  design or implementation plan when that task already has clear scope and
  acceptance criteria; resolve only genuine dependency ambiguities.

- Do not infer completion of a phase from a similarly numbered subtask or
  hardening plan. Re-check the canonical plan's full task list and acceptance
  gate before advancing to the next phase.

- When adding a workflow family, review every new public service, support
  module, controller, and job for a class-level responsibility comment and
  comments around non-obvious locking, idempotency, privacy, or state rules
  before considering the task review-ready.

- Never stage or commit changes without explicit user permission. Providing
  suggested commit commands is not permission to execute them; leave the
  worktree unchanged until the user authorizes the commit operation.

- When two canonical plans share database and service contracts, document the
  exact inter-plan handoff in the master roadmap and both implementation plans.
  A plan-level dependency is not enough when one task must create a real
  foreign-key target before another plan can proceed; never use a placeholder
  table or seed data to hide that ordering.

- When a later schema replaces an older cross-module key, update every
  defensive probe and its tests to use the canonical ownership path. For
  event-scoped orders, organization ownership is derived through the event and
  ticket commitments are derived through the product; do not reintroduce
  redundant `organization_id` or `ticket_type_id` columns just to satisfy an
  older query.

- When canonical plans contain inter-plan dependency gates, do not interpret
  “continue” as permission to start a different plan or to implement a later
  dependent task early. Before coding, state the executable sequence and label
  each task complete, pending by design, or prerequisite-gated; ask when the
  requested scope conflicts with that sequence.
