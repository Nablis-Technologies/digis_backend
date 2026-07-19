# API Filtering & Searching Guide

## How Requests Are Processed (Pipeline)

Every list (`index`) endpoint processes params in this order:

```
1. BASE SCOPE       → filters like active?, verified?, city?, genre?
2. SEARCH (q param) → Ransack text search on allowed attributes
3. SORTING          → order_by + order_direction
4. PAGINATION       → page + per_page (default: page 1, 25 per page, max 100)
```

---

## Public Catalog Endpoints (no auth required)

### `GET /categories`

```
GET /categories?page=1&per_page=50&order_by=name&order_direction=asc
```

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `page` | int | 1 | Pagination page |
| `per_page` | int | 25 | Max 100 |
| `order_by` | string | `id` | Allowed: `id`, `name`, `created_at` |
| `order_direction` | string | `desc` | `asc` or `desc` |

**Search support** — uses Ransack `q` param.

**Ransackable attributes:**

| Field | Ransack Predicate | Example |
|-------|-------------------|---------|
| `name` | `name_cont` | `q[name_cont]=music` |
| `slug` | `slug_cont` | `q[slug_cont]=conference` |
| `description` | `description_cont` | `q[description_cont]=live` |
| `active` | `active_true` | `q[active_true]=1` |

**Sorting** — Allowed: `id`, `name`, `created_at`

No catalog filters. Always returns only active categories.

**Examples:**
```bash
# Search categories by name
GET /categories?q[name_cont]=music

# Sort alphabetically
GET /categories?order_by=name&order_direction=asc
```

Response includes `id`, `name`, `slug`, `description`.

---

### `GET /venues`

```
GET /venues?city=Addis+Ababa&country=Ethiopia&verified=true&page=1&per_page=20&order_by=name&order_direction=asc
```

**Catalog Filters** (applied BEFORE search):

| Param | Type | Description |
|-------|------|-------------|
| `city` | string | Exact match on city name |
| `country` | string | Exact match on country name |
| `verified` | boolean | `true` or `false` — filter by verification status |

**Search support** — uses Ransack `q` param.

**Ransackable attributes:**

| Field | Ransack Predicate | Example |
|-------|-------------------|---------|
| `name` | `name_cont` | `q[name_cont]=grand` |
| `city` | `city_eq` | `q[city_eq]=Addis+Ababa` |
| `country` | `country_eq` | `q[country_eq]=Ethiopia` |
| `verified` | `verified_true` | `q[verified_true]=1` |
| `active` | `active_true` | `q[active_true]=1` |

**Sorting** — Allowed: `id`, `name`, `city`, `country`, `created_at`

Always returns only active venues.

**Examples:**

```bash
# Venues in Addis Ababa
GET /venues?city=Addis+Ababa

# Verified venues in Ethiopia, sorted by name
GET /venues?country=Ethiopia&verified=true&order_by=name&order_direction=asc

# Search venues by name
GET /venues?q[name_cont]=grand

# Venues in Addis matching "hall"
GET /venues?city=Addis+Ababa&q[name_cont]=hall

# Paginated results
GET /venues?page=2&per_page=10&order_by=created_at&order_direction=desc
```

Response includes `id`, `name`, `slug`, `city`, `country`, `capacity`, `verified`, `follower_count`, `profile_url`, `photos_urls`.

---

### `GET /artists`

```
GET /artists?genre=jazz&verified=true&page=1&per_page=20&order_by=name&order_direction=asc
```

**Catalog Filters** (applied BEFORE search):

| Param | Type | Description |
|-------|------|-------------|
| `genre` | string | Genre name — matches artists whose genres array contains this value |
| `verified` | boolean | `true` or `false` — filter by verification status |

**Search support** — uses Ransack `q` param.

**Ransackable attributes:**

| Field | Ransack Predicate | Example |
|-------|-------------------|---------|
| `name` | `name_cont` | `q[name_cont]=abdi` |
| `verified` | `verified_true` | `q[verified_true]=1` |
| `active` | `active_true` | `q[active_true]=1` |

**Sorting** — Allowed: `id`, `name`, `created_at`

Always returns only active artists.

**Examples:**

```bash
# Jazz artists
GET /artists?genre=jazz

# Verified artists
GET /artists?verified=true&order_by=name

# Search artists by name
GET /artists?q[name_cont]=abdi

# Jazz artists matching "band"
GET /artists?genre=jazz&q[name_cont]=band

# All artists paginated
GET /artists?page=1&per_page=30
```

Response includes `id`, `name`, `slug`, `genres`, `bio`, `verified`, `follower_count`, `profile_url`.

---

### `GET /organizations` (SEARCHABLE)

```
GET /organizations?q[name_cont]=tech&q[city_eq]=Addis+Ababa&page=1&per_page=10&order_by=name&order_direction=asc
```

**Catalog Filters:** None currently.

**Search support** — uses Ransack `q` param. `searchable?` is `true`.

**Ransackable attributes** (fields you can search on):

| Field | Ransack Predicate | Example |
|-------|-------------------|---------|
| `name` | `name_cont` | `q[name_cont]=tech` |
| `slug` | `slug_cont` | `q[slug_cont]=addis` |
| `description` | `description_cont` | `q[description_cont]=events` |
| `organizer_type` | `organizer_type_eq` | `q[organizer_type_eq]=company` |
| `category` | `category_eq` | `q[category_eq]=music` |
| `city` | `city_eq` | `q[city_eq]=Addis+Ababa` |
| `region` | `region_eq` | `q[region_eq]=Oromia` |
| `created_at` | `created_at_gt` | `q[created_at_gt]=2026-01-01` |

**Ransackable associations:** `memberships`, `reviews`

**Sorting** — Allowed: `id`, `name`, `slug`, `created_at`

**Examples:**

```bash
# Search organizations by name (contains "tech")
GET /organizations?q[name_cont]=tech

# Organizations in Addis, sorted by name
GET /organizations?q[city_eq]=Addis+Ababa&order_by=name&order_direction=asc

# Companies that mention events
GET /organizations?q[organizer_type_eq]=company&q[description_cont]=events

# Paginated with search
GET /organizations?q[name_cont]=addis&page=2&per_page=20
```

---

## Authenticated / Admin & Owner Endpoints (auth required)

These endpoints use `Core::Common` — `q` param search is **always on** (no `searchable?` guard). Pagination and sorting work the same as public endpoints.

### `GET /admin/users`

```
GET /admin/users?q[email_cont]=@gmail&q[deactivated_at_null]=1&page=1&per_page=20&order_by=email&order_direction=asc
```

**Searchable fields** (`Core::User`):

| Field | Predicate Example |
|-------|------------------|
| `email` | `q[email_cont]=@gmail` |
| `phone` | `q[phone_eq]=+251911000001` |
| `verified_at` | `q[verified_at_null]=1` or `q[verified_at_not_null]=1` |
| `deactivated_at` | `q[deactivated_at_null]=1` (active users) |
| `deactivated_reason` | `q[deactivated_reason_cont]=fraud` |

Searchable associations: `roles`

**Sorting** — Allowed: `id`, `name`, `created_at`, `updated_at`

**Examples:**
```bash
# Active users with gmail
GET /admin/users?q[email_cont]=@gmail&q[deactivated_at_null]=1

# Deactivated users
GET /admin/users?q[deactivated_at_not_null]=1

# Users with specific role
GET /admin/users?q[roles_code_eq]=SUPER_ADMIN
```

---

### `GET /admin/roles`

```
GET /admin/roles?q[name_cont]=admin&order_by=name&order_direction=asc
```

**Searchable fields** (`Core::Role`): `id`, `code`, `name`, `active`, `created_at`, `updated_at`

Searchable associations: `permissions`, `users`

**Examples:**
```bash
GET /admin/roles?q[active_true]=1&order_by=name
GET /admin/roles?q[code_eq]=SUPER_ADMIN
```

---

### `GET /admin/permissions`

```
GET /admin/permissions?q[resource_eq]=organizations&q[namespace_eq]=admin
```

**Searchable fields** (`Core::Permission`): `id`, `code`, `resource`, `action`, `namespace`, `active`, `created_at`, `updated_at`

Searchable associations: `roles`

**Examples:**
```bash
# Permissions for organizations resource
GET /admin/permissions?q[resource_eq]=organizations

# Permissions in admin namespace with create action
GET /admin/permissions?q[namespace_eq]=admin&q[action_eq]=create
```

---

### `GET /admin/venues`

```
GET /admin/venues?q[name_cont]=grand&q[city_eq]=Addis+Ababa&page=1&per_page=10
```

**Searchable fields** (`Events::Venue`): `name`, `city`, `country`, `verified`, `active`, `created_at`

**Sorting** — Allowed: `id`, `name`, `created_at`, `updated_at`

---

### `GET /admin/artists`

```
GET /admin/artists?q[name_cont]=abdi&q[verified_true]=1
```

**Searchable fields** (`Events::Artist`): `name`, `verified`, `active`, `created_at`

**Sorting** — Allowed: `id`, `name`, `created_at`, `updated_at`

---

### `GET /admin/categories`

```
GET /admin/categories?q[name_cont]=music
```

**Searchable fields** (`Events::Category`): `id`, `name`, `description`, `slug`, `active`, `created_at`, `updated_at`

**Sorting** — Allowed: `id`, `name`, `created_at`, `updated_at`

---

### `GET /admin/organizations`

```
GET /admin/organizations?q[name_cont]=addis&q[category_eq]=music&page=1&per_page=20
```

**Searchable fields** (`Organizations::Organization`): `name`, `slug`, `description`, `organizer_type`, `category`, `city`, `region`, `created_at`

Searchable associations: `memberships`, `reviews`

**Sorting** — Allowed: `id`, `name`, `slug`, `created_at`, `updated_at`

**Examples:**
```bash
# Music event organizers
GET /admin/organizations?q[category_eq]=music

# Organizations owned by a specific user (via memberships)
GET /admin/organizations?q[memberships_user_id_eq]=<user-uuid>
```

---

### `GET /admin/organizations/:organization_id/memberships`

```
GET /admin/organizations/123e4567-e89b-12d3-a456-426614174000/memberships?q[role_eq]=admin&q[status_eq]=active
```

**Searchable fields** (`Organizations::Membership`): `id`, `user_id`, `organization_id`, `role`, `status`, `created_at`, `updated_at`

Searchable associations: `user`, `organization`

**Examples:**
```bash
# All admins of an org
GET /admin/organizations/:org_id/memberships?q[role_eq]=admin

# Suspended members
GET /admin/organizations/:org_id/memberships?q[role_eq]=suspended
```

---

### `GET /organizations/owner` (Owner's own organizations)

```
GET /organizations/owner?page=1&per_page=10
```

Uses `Core::Common`. **Searchable fields**: same as `Organizations::Organization` above.

**Sorting** — Allowed: `id`, `name`, `slug`, `created_at`, `updated_at`

---

### `GET /organizations/owner/:organization_id/memberships`

```
GET /organizations/owner/org-uuid/memberships?q[role_eq]=staff&q[status_eq]=active
```

**Searchable fields** (`Organizations::Membership`): `id`, `user_id`, `organization_id`, `role`, `status`, `created_at`, `updated_at`

Searchable associations: `user`, `organization`

---

| Predicate | Meaning | Example |
|-----------|---------|---------|
| `_cont` | contains (case-insensitive) | `q[name_cont]=tech` |
| `_eq` | equals (exact) | `q[city_eq]=Addis+Ababa` |
| `_not_eq` | not equal | `q[category_not_eq]=sports` |
| `_start` | starts with | `q[name_start]=Add` |
| `_end` | ends with | `q[name_end]=Center` |
| `_gt` | greater than | `q[created_at_gt]=2026-01-01` |
| `_lt` | less than | `q[events_count_lt]=10` |
| `_in` | in a list | `q[category_in][]=music&q[category_in][]=sports` |
| `_not_in` | not in a list | `q[category_not_in][]=exhibition` |
| `_true` | is true | `q[verified_true]=1` |
| `_false` | is false | `q[verified_false]=1` |
| `_null` | is null | `q[description_null]=1` |
| `_not_null` | is not null | `q[description_not_null]=1` |

You can combine multiple predicates:
```
GET /organizations?q[name_cont]=addis&q[organizer_type_eq]=company&q[category_in][]=music&q[category_in][]=conference
```

---

## Pagination (all list endpoints)

**Request params:**

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `page` | int | 1 | Page number (omitting it returns default 25 results without pagination metadata) |
| `per_page` | int | 25 | Results per page (max 100) |

**Response includes pagination metadata when `page` is sent:**

```json
{
  "data": [ ... ],
  "pagination": {
    "current_page": 1,
    "per_page": 25,
    "total_count": 142,
    "total_pages": 6,
    "links": {
      "first": "...",
      "prev": null,
      "next": "...",
      "last": "..."
    }
  }
}
```

**Tip:** Omit `page` entirely to get a simple default 25-result list without pagination metadata. Send `page=1` to get full pagination info.

---

## Sorting (all list endpoints)

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `order_by` | string | `id` | Field to sort by (varies per endpoint — see allowed columns above) |
| `order_direction` | string | `desc` | `asc` or `desc` |

```bash
GET /venues?order_by=name&order_direction=asc
GET /artists?order_by=created_at&order_direction=desc
GET /organizations?order_by=slug&order_direction=asc
```

---

## Quick Reference

| Endpoint | Catalog Filters | Search (`q`) | Sortable Fields | Default Sort |
|----------|----------------|--------------|-----------------|-------------|
| **Public (no auth)** | | | | |
| `GET /categories` | none | yes | `id`, `name`, `created_at` | id desc |
| `GET /venues` | `city`, `country`, `verified` | yes | `id`, `name`, `city`, `country`, `created_at` | id desc |
| `GET /artists` | `genre`, `verified` | yes | `id`, `name`, `created_at` | id desc |
| `GET /organizations` | none | yes | `id`, `name`, `slug`, `created_at` | id desc |
| **Admin (auth required)** | | | | |
| `GET /admin/users` | — | yes | `id`, `name`, `created_at`, `updated_at` | id desc |
| `GET /admin/roles` | — | yes | `id`, `name`, `created_at`, `updated_at` | id desc |
| `GET /admin/permissions` | — | yes | `id`, `name`, `created_at`, `updated_at` | id desc |
| `GET /admin/categories` | — | yes | `id`, `name`, `created_at`, `updated_at` | id desc |
| `GET /admin/venues` | — | yes | `id`, `name`, `created_at`, `updated_at` | id desc |
| `GET /admin/artists` | — | yes | `id`, `name`, `created_at`, `updated_at` | id desc |
| `GET /admin/organizations` | — | yes | `id`, `name`, `slug`, `created_at`, `updated_at` | id desc |
| `GET /admin/organizations/:id/memberships` | — | yes | `id`, `created_at`, `updated_at` | id desc |
| **Owner (auth required)** | | | | |
| `GET /organizations/owner` | — | yes | `id`, `name`, `slug`, `created_at`, `updated_at` | id desc |
| `GET /organizations/owner/:id/memberships` | — | yes | `id`, `created_at`, `updated_at` | id desc |

---

## Summary: When to Use What

- **Dropdown / enum filter** (city, country, genre, verified) → use **catalog filter** params (`?city=...&verified=true`)
- **Text search** (find by name, description) → use **`q` param** with Ransack (`?q[name_cont]=tech`)
- **`q` param works everywhere** — all public and admin/owner endpoints support it
- **Paginate** → add `page` and optionally `per_page`
- **Sort** → add `order_by` and `order_direction`
- **Everything chains together** — you can combine all of them in one request
