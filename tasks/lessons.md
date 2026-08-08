# Lessons

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
