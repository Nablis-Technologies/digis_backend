# Seed profiles

Digis has one seed orchestrator and explicit profiles. The profile controls
which data is loaded; it does not change application behavior.

## Profiles

| Command/profile | Loads | Intended environment |
| --- | --- | --- |
| `bin/rails db:seed` | `base` only | Production baseline and safe reference setup |
| `DIGIS_SEED_PROFILE=preview bin/rails db:seed` | `base` + comprehensive preview fixtures | Render preview, CI seed verification, local API testing |
| `DIGIS_SEED_PROFILE=dev bin/rails db:seed` | `base` + preview + local extensions | Local development |
| `bin/rails db:seed:dev` | The `dev` profile | Local development convenience command |

The profile files are:

- `db/seeds.rb`: profile orchestrator and production-safety guard;
- `db/seeds/base.rb`: reference data and bootstrap access only;
- `db/seeds/preview.rb`: comprehensive, idempotent test fixture;
- `db/seeds/dev.rb`: local `dev` profile entry point;
- `db/seeds/dev_extensions.rb`: additive local-only data hook.

The preview profile includes separate disposable `Cancellation Drill Event` and
`Cancellation Outcomes Drill Event` fixtures. The first is safe for the
zero-payment cancellation drill; the second remains available for the
accepted/pending/failed payment-outcome workflow. Seeds create the event,
product, access, and allocation inputs only; real checkout, webhook, refund,
and cancellation commands produce terminal states.

## Production safety

Production rejects `preview` and `dev` profiles unless the runtime is explicitly
identified as the Render preview service with both `RENDER_PREVIEW=true` and a
preview database URL. Preview users, Chapa test credentials, synthetic events,
scanner fixtures, and test financial inputs must never be loaded into a normal
production database.

The base profile intentionally does not create organizations, venues, events,
test payments, tickets, scanner tokens, refunds, or payouts. Real production
onboarding and operational commands create those records.

## Scenario rule

Seeds create valid starting inputs through existing application services. They
do not fake terminal financial or admission outcomes with direct status
updates. Refunds, cancellations, scanner revocations, payment acceptance, and
payout dispatch must be exercised by their real commands/jobs.

## Deployment and CI

Render sets `DIGIS_SEED_PROFILE=preview`. The preview Docker entrypoint runs
`bin/rails db:seed` automatically when `core_users` is absent, which initializes
a new preview database without repeating the memory-heavy fixture graph on
every restart. `DIGIS_FORCE_SEED` is intentionally not declared in
`render.yaml`; set it to `true` manually in the Render service environment for
an intentional fixture refresh, then restore it to `false`. For a complete
disposable preview reset, set `DIGIS_RESET_DATABASE=true` manually and deploy
once; the entrypoint runs `db:seed:replant` only when the preview database URL is
present, then restore it to `false`. Keeping these toggles out of Blueprint
management prevents a sync from overwriting the one-time operator choice. CI sets the same profile before
`db:seed:replant`, so seed assertions cover the same
comprehensive fixture shape as the preview deployment.

The seed code is idempotent. A normal preview redeploy converges the fixture;
it does not require a database reset. Reset only when a clean schema baseline
or an explicitly disposable drill requires it.

## Preview memory boundary

The Render free preview intentionally keeps the production-shaped Puma and
Solid Queue process profile. Its 512 MB memory ceiling is an accepted testing
environment limitation, not a production-readiness signal. The entrypoint
avoids repeating the full seed graph on ordinary restarts, but operators may
still need to restart the preview service after memory pressure. Do not mark
the production launch gate green from this preview resource profile.
