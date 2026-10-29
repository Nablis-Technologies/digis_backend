# Private User Profile and Self-Service Management

**Status:** Approved; backend implementation in progress. Preview verification remains pending.

## Goal

Persist the user's first and last name collected during signup and provide a
self-service API for maintaining those fields and an optional avatar. Keep
account identity/security separate from profile data. Profiles are private by
default; no public user directory or profile lookup is introduced.

This design addresses G-14 (signup name currently dropped) and G-47
(self-service profile editing). They share the profile model but remain
independently testable requirements.

## Current-state evidence

- `Core::User` owns authentication identity (`phone`, `email`, verification,
  password digest), roles, permissions, and many domain associations. There is
  no user-profile model or persisted user name.
- The signup request currently permits email, phone, and password fields but
  not the frontend's `name` input. `Core::Signups::Complete` upgrades an
  existing phone-verified shadow user and persists only those permitted
  identity fields.
- `Core::UserAuthSerializer` is returned from login, signup, refresh, and the
  current `GET /auth/me`; it includes roles and permissions used by the client.
  It is also used in non-self contexts, including organization membership
  serialization and ticket-transfer responses. Adding private profile fields
  to that shared serializer without separating self and other-user projections
  could expose them to unrelated users.
- Project instructions describe strict loading as globally enabled in test,
  but the current source tree does not contain the corresponding runtime
  configuration. Confirm or add the test setting during implementation; do
  not assume it is active in preview unless that environment is explicitly
  configured.
- `/admin/users` is an administrative resource. It is not a self-service
  profile endpoint.
- Organizations, artists, and venues use Active Storage for their own
  `profile` attachments. Those are separate domain profiles and do not provide
  a private user-avatar contract.

## Product and privacy decisions

1. **One private account profile.** Each completed account may have one
   `Core::UserProfile`. It stores first and last name and an optional avatar.
   It is not an organization, artist, venue, or public-discovery profile.
2. **Private by default.** The self-service API exposes the profile only to
   its owner. No public profile route, directory, or visibility flag is added
   in this phase. A future public-profile feature must add explicit opt-in and
   a separate allow-listed projection.
3. **Organizer visibility is event-scoped.** Authorized organizers may see
   attendee names in the context of their own event and attendee records. This
   does not make user profiles publicly discoverable. The profile avatar is
   not exposed to organizers in this phase. Event registration answers remain
   authoritative when a ticket is registered for someone other than the
   account holder.
4. **Identity changes remain separate.** Phone and email changes are not
   accepted through profile update. Phone changes continue through verified
   phone-identity flows; email changes require their own verification flow.
   Roles, permissions, verification state, deactivation state, and credentials
   are never profile-editable.
5. **`/user` is the canonical current-user resource.** Replace the current
   `GET /auth/me` contract with authenticated `GET /user` and `PATCH /user`.
   Do not accept a user ID in these requests. Coordinate the frontend/backend
   cutover and remove `/auth/me` in that release; do not retain a compatibility
   alias. Login/signup/refresh responses use the same current-user projection
   as `/user`.
6. **No guessed backfill.** Existing accounts have no stored name to migrate.
   Do not infer names from email addresses or phone numbers. Existing accounts
   without a profile receive an incomplete/empty profile projection and can
   complete it through `PATCH /user`.

## Data model and lifecycle

Create one table in one new migration: `core_user_profiles`.

- UUIDv7 primary key.
- Required unique `user_id` foreign key to `core_users`.
- Required `first_name` and `last_name`, each normalized to Unicode NFC and
  trimmed at the edges, then validated as nonblank with a bounded length
  (maximum 100 characters). Preserve Unicode names, including Ge'ez/Amharic;
  reject control characters, but do not impose an ASCII-only or letters-only
  pattern, or a uniqueness constraint. Labels and help text should describe
  given name and additional/father's name without implying that every culture
  uses an inherited family surname.
- Optional `avatar` Active Storage attachment; attachment metadata remains in
  the existing Active Storage tables.
- Timestamps and the repository's standard foreign-key/index constraints.

`Core::User` has an optional one-to-one profile association. Phone-verified
shadow users may exist without a profile. `Core::Signups::Complete` creates
the profile with first/last name in the same transaction that completes
signup, assigns the default role, and records signup evidence. A read of
`GET /user` must never create a profile or otherwise mutate state. A profile
update for an existing account without a profile may create it atomically.
`full_name` is a computed presentation value (`first_name` + one space +
`last_name`, trimmed), not a persisted column.

The database should not contain speculative fields such as bio, locale,
pronouns, public visibility, or social links until an approved client surface
requires them. Add such fields as typed columns/attachments with explicit
privacy and validation rules when needed; do not use a generic JSONB profile
blob.

## API contract

All routes require normal user authentication. The server derives the target
user exclusively from `current_user`.

Implement the self resource in `Core::UsersController` as the singular
`/user` resource with `show` and `update` actions. Add `GET /user/avatar` as a
dedicated authenticated action on the same controller; it also derives the
profile from `current_user`, never from a route ID or query parameter.

### Read current user

    GET /user
    Authorization: Bearer <user_jwt>

Return the existing success/data envelope with the serialized user object
directly in `data` (not wrapped again in `data.user`). Preserve the existing
user fields and wire types: `id`, `email`, `phone`, `verified_at`,
`created_at`, `updated_at`, `permissions`, and `roles`. Add exactly one nested
`profile` field: `null` when no profile exists, otherwise an object with
`first_name`, `last_name`, computed `full_name`, and `avatar_url` (the relative
path `/user/avatar` when present, otherwise `null`). Do not add a redundant
`has_avatar`; clients can test whether `avatar_url` is null. The profile
portion is:

```json
{
  "profile": {
    "first_name": "አስቴር",
    "last_name": "በቀለ",
    "full_name": "አስቴር በቀለ",
    "avatar_url": "/user/avatar"
  }
}
```

An account without a profile returns `"profile": null`. This endpoint is
read-only and does not create a profile. Login/signup/refresh continue their
existing response envelopes with the same serialized object under `data.user`
alongside token fields; only `/user` returns that object directly as `data`.
The `roles` object shape and permissions contract remain unchanged.

Use `Core::CurrentUserSerializer` for the current user in login, signup,
refresh, `GET /user`, and `PATCH /user`. Only use it where the serialized user
is the principal receiving or using those credentials. Replace non-self uses
of `Core::UserAuthSerializer` with `Core::UserSummarySerializer`; keep the
summary minimal by default and make `full_name`, phone, or email opt-in only
for the specific response whose authorization policy permits each field. Do
not make the review's proposed `{ id, phone, email, full_name }` a universal
collaborator projection. Audit every current `Core::UserAuthSerializer` call
site, including membership and ticket-transfer responses, before removing or
repurposing it. Keep the existing current-user `roles` object shape and
permissions contract; this feature does not change RBAC serialization.

### Update current user

    PATCH /user
    Authorization: Bearer <user_jwt>
    Idempotency-Key: <stable-client-key>
    Content-Type: application/json or multipart/form-data

Name-only request:

    { "profile": { "first_name": "Aster", "last_name": "Bekele" } }

Avatar replacement uses the same authenticated profile mutation with a
multipart `profile[avatar]` file. Removal uses `profile[remove_avatar]=true`;
replacement and removal cannot be requested in the same update. Strong
parameters allow only `first_name`, `last_name`, `avatar`, and
`remove_avatar`. No `id`, `user_id`, email, phone, roles, permissions,
verification, password, or account-status fields are accepted.

The response returns the same safe current-user projection used by `GET
/user`. The mutation is idempotent and auditable. Audit metadata records the
actor, profile/user IDs, action, and changed field names, but not the submitted
names, file contents, storage keys, or bearer URLs.

Supplying a new `avatar` together with truthy `remove_avatar` is invalid.
Return `422 Unprocessable Entity` with code `avatar_operation_conflict` before
attaching, replacing, or removing anything; do not silently choose one
operation. Parse the multipart boolean consistently so a false value is not
treated as a request to remove the avatar.

### Avatar handling

- Use `has_one_attached :avatar` on `Core::UserProfile` and the existing
  Active Storage infrastructure.
- Accept JPEG, PNG, and WebP images up to 5 MiB. Reject unsupported MIME types
  and oversized files; inspect the bytes with the configured image decoder,
  not only the client-supplied content type. During `PATCH /user`, successfully
  decode the upload and process the exact 200x200 `thumb` variant before
  replacing the current attachment. If decoding or transformation proves the
  submitted file malformed/unsupported, return `422 Unprocessable Entity` with
  `invalid_avatar`; if the processor or storage fails unexpectedly, return a
  generic `503 Service Unavailable` with `avatar_processing_unavailable`.
  Both failures clean up any temporary or unattached blob and leave the
  existing avatar unchanged. Do not blanket-rescue operational failures as
  user validation errors. This catches bad inputs at ingestion but does not
  eliminate later storage or processor failures.
- Provide one fixed `thumb` variant using a 200x200 `resize_to_fill` square
  crop. `GET /user/avatar` always serves this variant; do not accept arbitrary
  transformations or a client-selected variant. Replacing an avatar must
  detach/purge the previous attachment according to normal Active Storage
  lifecycle. Verify variant generation in the deployed preview environment
  using its configured image processor; the Ruby gem being present does not
  prove the host has all required image-processing libraries.
- The user projection may include only the fixed relative path `/user/avatar`
  when an avatar exists; it must not serialize a permanent/public Active
  Storage blob URL or signed blob ID. `GET /user/avatar` authenticates the
  caller before evaluating conditional requests, resolves only
  `current_user.profile.avatar`, and serves the processed image through the
  authenticated endpoint. It returns an opaque ETag scoped to the
  profile/avatar revision and
  `Cache-Control: private, max-age=0, must-revalidate`; a matching
  `If-None-Match` returns `304 Not Modified` with no image body, but only after
  authorization against the current account. The ETag must change when the
  current user's avatar changes and must not contain a storage key or PII.
  If an authenticated caller has no profile or attached avatar, return
  `404 Not Found` with code `avatar_not_found`; do not redirect or return a
  304 for a missing avatar. If an unexpected processor/storage failure occurs
  while serving an attached image, return a generic, non-sensitive
  `503 Service Unavailable` response with code `avatar_unavailable` and log
  only safe diagnostic metadata, never the image or storage URL.
  Keep the JSON profile response and avatar mutations `private, no-store`.
  Do not redirect to a signed storage URL or expose one to the client. Never
  persist or log signed URLs.
- Avatar bytes are never included in organizer attendee responses in this
  phase.

## Signup and profile response behavior

- Replace the single signup `name` input with `first_name` and `last_name` in
  the user request and frontend contract. Update `Core::AuthController` strong
  parameters and `Core::Signups::Complete` to persist both values on the new
  profile. Signup fails with field-specific validation if either is missing
  or invalid.
- Login/signup/refresh and `GET /user` must use one consistent self/current-user
  projection, including the names and current roles/permissions. Do not add
  these fields to shared nested user serialization; use a separate
  allow-listed projection for membership and other-user contexts.
- Existing completed accounts with no profile are not silently assigned
  fabricated names. The frontend can prompt them to complete their profile;
  `PATCH /user` creates the profile when valid first and last names are
  supplied.
- A phone-verified shadow user is not treated as a fully registered profile.
  The profile is created only as part of completed signup or a deliberate
  self-service completion, never as a side effect of a read or invitation
  lookup.
- Eager-load all associations required by the self projection at the relevant
  controller/serialization boundary: `roles: :permissions` and
  `profile: { avatar_attachment: :blob }`. Apply the profile preload
  independently of whether roles are already loaded; do not put serialization
  preloading in `Core::AuthService`, which owns authentication/token behavior
  rather than response rendering. The `:permissions` preload is needed because
  the existing role serializer nests permission records; preloading only
  `:roles` is insufficient. Cover login/signup/refresh, `/user`, and
  avatar-serving paths with strict-loading tests. Verify that the test
  environment actually enables strict loading; preview is covered only if its
  runtime configuration enables it.

## Errors and security boundaries

- Missing authentication: standard unauthorized response.
- Invalid/blank/oversized name fields: typed validation response; do not save
  a partial profile during signup or first-time profile creation. On an
  existing profile, omitted PATCH fields remain unchanged so either name can
  be edited independently.
- Unsupported, malformed, or oversized avatar: typed validation response; do
  not replace the current avatar.
- Avatar absent on `GET /user/avatar`: authenticated `404 avatar_not_found`;
  avatar-plus-removal request: `422 avatar_operation_conflict`; upload decode
  failure: `422 invalid_avatar`; unexpected upload processing/storage failure:
  generic `503 avatar_processing_unavailable`; unexpected serving infrastructure
  failure: generic `503 avatar_unavailable`.
- Profile access is owner-only. No endpoint accepts an arbitrary user ID.
- Organizer access is granted only through existing event-scoped attendee
  authorization and projections. Private profile state does not suppress the
  attendee's event-scoped name, and event registration answers for another
  ticket holder do not get overwritten by the buyer's profile name.
- `/user` response and avatar mutation responses use private/no-store caching.
  Avatar-byte responses use the authenticated conditional-cache policy
  (`private, max-age=0, must-revalidate` plus ETag). Never include avatar
  storage keys or signed URLs in logs or audits.
- Require `Idempotency-Key` on `PATCH /user` in accordance with the project
  mutation convention. Same key and payload replays the same outcome; key
  reuse with changed profile data returns the standard idempotency conflict.

## Migration and rollout

- Add a new one-table migration for `core_user_profiles`; do not modify the
  existing `core_users` migration because this is a new table. Update
  `db/structure.sql` from the test database.
- Update the backend Postman collection and the separate frontend contract to
  use `GET/PATCH /user`, first/last name fields, and authenticated avatar
  behavior. Remove `GET /auth/me` as part of the coordinated frontend/backend
  cutover; do not leave two competing current-user endpoints or a compatibility
  alias.
- No development or Render database reset is needed for this additive new
  table. Existing Render profile data does not exist and must not be fabricated.
- Automatic SMS/phone verification, login, and role assignment remain owned by
  their existing commands; profile work does not change those flows.

## Acceptance criteria

1. Signup persists first and last name in a private `Core::UserProfile` and
   returns them consistently from signup, login, refresh, and `GET /user`.
2. Shadow users can exist without a profile; signup creates the profile
   transactionally, and `GET /user` never writes one.
3. Authenticated users can read/update only their own profile via `/user`,
   with no user ID in the request and no access to admin user mutation fields.
4. A profile update is idempotent, audited without raw profile values, and
   rejects malformed names/avatar files without replacing valid existing
   data.
5. Avatar is optional, private, decoded and thumbnail-processed during upload,
   and never exposed in global user search or organizer attendee projections.
   Failed replacement preserves the prior avatar. The authenticated 200x200
   endpoint returns 404 when absent, supports ETag revalidation, and
   authorizes before returning image bytes or `304 Not Modified`; serving
   infrastructure errors are handled without exposing internals.
6. Authorized event organizers can see first/last name only in their own
   event-scoped attendee context; public user discovery does not exist.
7. Login/signup/refresh and `/user` return the same private self projection,
   while nested membership/other-user projections do not expose profile data.
8. The frontend no longer depends on `/auth/me`; no duplicate current-user
   endpoint or compatibility alias remains after migration.
9. Postman, signup, self-user projection, and `/user` tests cover the new
   contract, shadow-user lifecycle, owner scoping, idempotency, audit privacy,
   avatar upload decoding and thumbnail processing, failed-replacement
   preservation, the avatar-operation conflict, absent-avatar 404, conditional
   caching, strict-loading preloads, and event-scoped name visibility. Preview
   smoke testing confirms the configured image processor can generate the
   200x200 variant.

## Explicitly deferred

- Public/discoverable user profiles or a people directory.
- Organizer-facing avatar display.
- Email/phone editing, verification, password change, and account deactivation
  through `/user`.
- Bio, locale/timezone, pronouns, social links, profile completion scoring, and
  profile-specific visibility settings.
