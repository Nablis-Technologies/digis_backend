# Lessons

- For public service pricing and policy research, prefer public documentation,
  read-only web fetches, and search. Do not make browser sign-in or account access
  a prerequisite when the user wants general limits and terms rather than an
  account-specific audit.

- Render MCP can update preview environment variables and run read-only database
  queries, but it cannot inspect effective runtime environment values or execute
  a writable shell command on the free service. When a preview reset is needed,
  provide an explicit, preview-URL-guarded reset path in the checked-in entrypoint
  and verify it through the deployment logs and database state.

- Shell entrypoints must be syntax-checked after every conditional change; do not
  carry Ruby-style postfix conditionals such as `return 0 if ...` into Bash.

- For external API contracts, distinguish documented examples and prose from
  the provider's explicit required/optional parameter table. Chapa lists
  `first_name`, `last_name`, and `email` as optional for transaction
  initialization; include optional values when present and omit them when
  absent. Do not add environment gates or synthetic values for this rule.

- When validating a deployed seeded environment, use the actual fixture
  identifier returned by the live login response (the seeded admin phone may
  differ from the local fixture email), verify the deployed commit, and treat
  readiness component output as a real production signal. Do not infer seed or
  configuration state from the Render Blueprint alone.

- When a user asks to finish a plan, reconcile the canonical plan checkboxes with the actual committed code before advancing; distinguish completed implementation from remaining gated tasks and update the plan as each tranche is verified.

- When presenting an interactive choice, do not treat a missing answer as approval or
  end the task as though the user chose. Keep the work at that decision point; if
  the user says they have not answered, re-present the choice with the ask-user
  tool and continue only after their response. Independent, already-approved work
  may proceed while an optional clarification is pending.

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

- Performance budgets measured inside the full parallel CI suite are
  environment-sensitive. Keep a strict local budget, define an explicit CI
  allowance or isolate the benchmark in a dedicated job, and do not treat one
  fast local run as proof that an absolute CI threshold is stable.

- In Ruby, a method call placed after a `rescue SomeError => error` body is
  still inside that rescue clause; it is not another rescue handler. Keep the
  shared rescue wrapper around the transaction and add regression tests for
  malformed idempotency keys and persistence errors.

- When Pundit uses a custom namespaced policy resolver, rename policies only
  together with the resolver's lookup order. Empty aliases may be required by
  response serialization even when authorization passes an explicit policy
  class; remove them only after canonical model-named policies resolve in both
  public and admin contexts.

- Billing payment subjects must translate command aborts into typed Results,
  preserve succeeded provider evidence, and create durable refund obligations
  for late or duplicate charges. Keep credit reversal evidence append-only;
  if credits were already spent, a compensating entry may make the derived
  balance negative so the chargeback is never silently dropped.

- Billing callbacks must distinguish a failed superseded attempt from an
  authoritative purchase failure. Never downgrade a paid purchase or reverse
  its credits because an older retry failed; reconcile only the payment and
  top-up identity that actually owns the transition.

- A delayed accepted-credit event after a compensating refund must be an
  idempotent no-op only when matching refund evidence exists. Do not broaden a
  reconciler to refund every unaccepted succeeded payment, because a provider
  webhook may already prove that the money was returned.

- Campaign delivery tests must exercise rendered variables, provider exceptions,
  and retry exhaustion through both singular and batched settlement paths.
  A green test with a static message or one retry does not prove dispatch is
  safe, complete, or financially settled.

- When an aggregate service returns a Result, preserve its value's contract at
  every caller boundary. Batched jobs must receive their declared outcome
  object, while singular callers may receive the persisted model; never pass a
  model-shaped retry result into a batch settlement API.

- Every response path needs the policy for the object it actually returns, not
  merely the object authorized at the request boundary. For scoped child
  resources, keep the child policy and serializer profile explicit so Pundit
  cannot turn a successful command into a 500 during serialization.

- Lifecycle commands that change campaign state or release credit holds must
  record request-bound actor evidence, not merely validate an idempotency key.
  Keep quota semantics explicit when the policy intentionally measures launch
  attempts rather than provider delivery consumption.

- When a lifecycle command accepts a terminal no-op, validate required inputs
  before the no-op and bind actor/request details with canonical JSON. Preserve
  retry cursors while resetting only fresh-recovery cursors, so bounded workers
  cannot skip unclaimed work after a partial failure.

- Retention must distinguish durable organizer address books from ephemeral
  campaign-recipient material. A stale provider attempt is not a failed result:
  retry it with the original idempotency key, and refund only work that never
  reached the provider.

- JSON array payloads are still unpermitted `ActionController::Parameters` at
  the controller boundary. Permit each row before converting it to a Hash;
  calling `to_h` directly turns a valid API request into a 500.

- Idempotent audit writers must make uniqueness races savepoint-safe. Use an
  atomic create-or-find operation that does not leave the surrounding
  transaction aborted, and rescue the actual nested `ReplayConflict` type at
  every command boundary.

- A provider status page being green does not validate a merchant request.
  Classify a payment failure from the exact provider response, request
  contract, account mode, and merchant dashboard evidence; do not label a
  request-specific HTTP 500 a provider-wide outage without checking those
  boundaries.

- Treat authenticated provider responses as contract evidence even when the
  vendor documentation disagrees. Normalize documented object and observed
  array envelopes explicitly, and test the live envelope so a missing path
  such as `data.items` cannot silently turn a valid response into an empty
  capability set.

- Reproduce a payment-provider failure outside the application with the same
  operation, credentials, and payload before changing application code. A
  successful unrelated endpoint does not validate the target operation; retain
  the provider request ID when a structured error supplies one.

- Every implementation must include focused regression coverage and run the
  relevant tests in the same task. Follow red/green verification, and keep the
  tracker status explicitly unverified until behavioral tests pass; static
  checks alone do not establish that a bug fix works.

- Provider reference constraints are separate from client idempotency
  constraints. Keep the full client key for local replay and the native
  `Idempotency-Key` header, but derive and persist a provider-safe reference
  when the gateway imposes a shorter `merchant_reference` limit; never truncate
  an identifier without a durable correlation strategy.

- Public discovery must not let unrelated page neighbors or arbitrary result
  caps change an event's business state. Stream child records in fixed-size
  batches, fold per-event results, and test total rows visited and maximum batch
  size in addition to SQL query count. Inventory checks must distinguish access
  dates (including stream) from physical venue demand; lock/validate all access
  dates, but consume venue capacity only for physical accesses.
