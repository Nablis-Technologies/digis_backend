# Postman Collection Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the primary Digis Postman collection into clear Auth, Public, Account, Organizer, and Admin surfaces while adding complete route coverage, reusable variables, formatted bodies, and developer-friendly response scripts.

**Architecture:** Preserve the existing request definitions and examples where valid, but rebuild the collection's folder tree from route ownership instead of appending feature folders at the root. Collection-level variables remain limited to base URL and authentication tokens; resource identifiers are defined at the lowest folder that owns them. The filtering/search collection remains a separate companion collection.

**Tech Stack:** Postman Collection v2.1 JSON, Ruby/Rails route metadata, JavaScript Postman test scripts.

---

### Task 1: Inventory and normalize the existing collection

**Files:**
- Modify: `postman/Digis API_collection.json`
- Reference: `config/routes.rb`

- [ ] Parse the current collection as JSON before changing it and recursively flatten every request while retaining its current folder path, request name, method, URL, headers, body, response examples, and test events.
- [ ] Compare normalized method/path pairs with `Rails.application.routes.routes` so the final collection preserves existing coverage and identifies missing requests without treating concrete follow routes as separate from the constrained follow route.
- [ ] Keep `postman/Digis API - Filtering & Searching.postman_collection.json` unchanged and out of the primary collection transformation.

### Task 2: Rebuild the folder tree around API consumers

**Files:**
- Modify: `postman/Digis API_collection.json`

- [ ] Keep collection-level variables `baseUrl`, `accessToken`, and `refreshToken`.
- [ ] Create these top-level folders in this order:

```text
Auth
Public
Account
Organizer
Admin
```

- [ ] Place public discovery requests under `Public > Discovery` and public event/product requests under `Public > Events`.
- [ ] Place follow/follower actions that operate on public resources under `Public > Social`.
- [ ] Place `POST /ticketing/audience_authorizations` under `Public > Ticketing` with no inherited authorization header.
- [ ] Place `/feed` and `/users/:user_id/following` under `Account`.
- [ ] Place event-management resources under `Organizer > Events`.
- [ ] Place event-product, pricing, quote, access, zone, allocation, and ticketing requests under `Organizer > Events > Event Products` so they inherit `eventId` and can define `productId` at the event-product folder.
- [ ] Place inventory, promotion, and promotion-code requests under `Organizer > Events > Catalog` so event-scoped catalog variables remain inherited from the organizer event folder.
- [ ] Place owner organizations, memberships, documents, and organizer verification under `Organizer > Organizations`.
- [ ] Place admin users, roles, permissions, categories, venues, artists, events, organizations, memberships, legal documents, and verification under `Admin`.
- [ ] Keep each resource's requests together and order them as `List X`, `Get X`, `Create X`, `Update X`, `Delete X`, followed by custom actions.

### Task 3: Add resource variables at their lowest common ancestor

**Files:**
- Modify: `postman/Digis API_collection.json`

- [ ] Define `eventId` at the `Organizer > Events` folder level and use `{{eventId}}` for nested event paths and event query parameters.
- [ ] Define `productId` at the `Organizer > Events > Event Products` folder level and use it for all event-product paths and product-related bodies.
- [ ] Define `ticketTypeId` at `Organizer > Events > Event Products > Ticketing > Ticket Types` and use it for ticketing request bodies and audience authorization.
- [ ] Define `accessCodeId` and `invitationId` at the corresponding child folders.
- [ ] Define `promotionId`, `promotionCodeId`, `productPriceId`, `productInventoryId`, `organizationId`, `membershipId`, `legalDocumentId`, and `documentType` at their corresponding resource folders where needed.
- [ ] Define `idempotencyKey` at the lowest folder common to requests that use it, and use `{{$guid}}` only where a fresh key is required for each execution.
- [ ] Replace literal IDs and Postman `:id` URL placeholders with collection/folder variables, including the current `/catalog/product_inventories/1` request.
- [ ] Retain Postman path-variable metadata only when the identifier cannot be represented by a collection or folder variable; otherwise use `{{resourceId}}` consistently in both `raw` and `path` fields.

### Task 4: Complete route coverage and format request bodies

**Files:**
- Modify: `postman/Digis API_collection.json`

- [ ] Add `List Product Prices` and `Get Product Price`.
- [ ] Add `Get Product Inventory` using `{{productInventoryId}}`.
- [ ] Add `Delete Legal Document`.
- [ ] Correct owner-document requests to use `PATCH /organizations/owner/{{organizationId}}/documents` and `GET /organizations/owner/{{organizationId}}/documents/{{documentType}}`.
- [ ] Add `Get Feed` if it is not already present.
- [ ] Add ticket-type `List/Get/Create/Update/Delete` requests for the nested singular `ticket_type` route.
- [ ] Add access-code `List/Get/Create/Delete` requests.
- [ ] Add invitation `List/Get/Create/Delete` requests.
- [ ] Add `Idempotency-Key: {{idempotencyKey}}` to access-code and invitation create requests, matching controller requirements.
- [ ] Add `Content-Type: application/json` to every request with a JSON body.
- [ ] Use valid, pretty-printed JSON bodies with current field names from the controller strong parameters and existing examples.
- [ ] Replace placeholder strings such as `<ticket_type_id>` with `{{ticketTypeId}}`.
- [ ] Preserve secrets only in response examples where the endpoint intentionally returns them once; do not place access-code or invitation secrets in request bodies or collection variables.

### Task 5: Normalize names and add developer test scripts

**Files:**
- Modify: `postman/Digis API_collection.json`

- [ ] Normalize request names to `List X`, `Get X`, `Create X`, `Update X`, and `Delete X`; use explicit action names such as `Publish Promotion` only for non-CRUD actions.
- [ ] Add a `List Events` test that asserts a successful response and sets `eventId` from the first response item using `pm.collectionVariables.set("eventId", ...)` when an item exists.
- [ ] Add equivalent first-item ID capture scripts to product list endpoints, event-product list endpoints, ticket-type list endpoints, access-code list endpoints, invitation list endpoints, product-price list endpoints, product-inventory list endpoints, and other list requests where the ID is useful for the next request.
- [ ] Use defensive extraction for both direct arrays and the project's `{ success, data }` response shapes.
- [ ] Add status and response-shape tests to all newly added requests.
- [ ] Add response examples for newly added requests only when the response shape is known from serializers/controllers; do not invent undocumented fields.
- [ ] Explicitly set `auth: { "type": "noauth" }` on public requests that must not inherit collection-level bearer authentication.

### Task 6: Validate the final collection

**Files:**
- Verify: `postman/Digis API_collection.json`
- Verify: `config/routes.rb`

- [ ] Parse the final JSON with Ruby's `JSON.parse` and confirm it is valid Postman v2.1 JSON.
- [ ] Assert every request has a method, URL, and a normalized path matching a Rails route unless it is a documented Postman example alias.
- [ ] Assert no URL contains hardcoded numeric IDs, UUID literals, `<...>` placeholders, or unresolved `:id` placeholders where a resource variable is defined.
- [ ] Assert `baseUrl`, `accessToken`, and `refreshToken` exist at collection level and resource IDs are not duplicated at collection level.
- [ ] Assert all idempotent access-code and invitation create requests contain `Idempotency-Key`.
- [ ] Assert all JSON request bodies parse successfully and are formatted with two-space indentation.
- [ ] Run `git diff --check`.
- [ ] Run `bundle exec rubocop` only if Ruby validation helpers are added; do not alter unrelated baseline offenses.
