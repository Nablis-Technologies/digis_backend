# This file should ensure the existence of records required to run the application in every environment.
# The code here is idempotent — safe to run multiple times without duplicating data.
# This branch uses the canonical seed as the shared development, preview, and API-test fixture.
# The synthetic Chapa records below must not be carried into a production seed policy.
#
# Load with: bin/rails db:seed

puts "=" * 60
puts "🌱 Digis Backend — Seeding Database"
puts "=" * 60

# ─────────────────────────────────────────────
# 1. Core Users
# ─────────────────────────────────────────────
puts "\n👤 Seeding users..."

admin_user = Core::User.find_or_create_by!(phone: "251911000001") do |u|
  u.email = "admin@digis.et"
  u.password = "password123"
  u.verified_at = Time.current
end

organizer_user = Core::User.find_or_create_by!(phone: "251911000002") do |u|
  u.email = "organizer@digis.et"
  u.password = "password123"
  u.verified_at = Time.current
end

attendee_user = Core::User.find_or_create_by!(phone: "251911000003") do |u|
  u.email = "attendee@example.com"
  u.password = "password123"
  u.verified_at = Time.current
end

puts "✓ #{Core::User.count} users seeded"

# ─────────────────────────────────────────────
# 2. Roles
# ─────────────────────────────────────────────
puts "\n🎭 Seeding roles..."

super_admin_role = Core::Role.find_or_create_by!(code: "SUPER_ADMIN") do |r|
  r.name = "Super Admin"
  r.description = "Full platform access — manages all organizations, users, and settings"
  r.active = true
end

admin_role = Core::Role.find_or_create_by!(code: "ADMIN") do |r|
  r.name = "Admin"
  r.description = "Organization admin — manages events, tickets, and team members"
  r.active = true
end

organizer_role = Core::Role.find_or_create_by!(code: "ORGANIZER") do |r|
  r.name = "Organizer"
  r.description = "Event organizer — creates and manages events"
  r.active = true
end

user_role = Core::Role.find_or_create_by!(code: "USER") do |r|
  r.name = "User"
  r.description = "Default end-user role — can browse and purchase tickets"
  r.active = true
end

core_admin_role = Core::Role.find_or_create_by!(code: "CORE_ADMIN") do |r|
  r.name = "Core Admin"
  r.description = "Core-level operational access — manages platform users, roles, and permissions"
  r.active = true
end

support_role = Core::Role.find_or_create_by!(code: "SUPPORT") do |r|
  r.name = "Support"
  r.description = "Support-level access — can view users, deactivate accounts, and view audit logs"
  r.active = true
end

puts "✓ #{Core::Role.count} roles seeded"

# ─────────────────────────────────────────────
# 3. Permissions
# ─────────────────────────────────────────────
puts "\n🔐 Seeding permissions..."

permissions = [
  # User management
  { resource: "user", action: "index", namespace: "core", description: "List all users" },
  { resource: "user", action: "show", namespace: "core", description: "View user details" },
  { resource: "user", action: "create", namespace: "core", description: "Create new users" },
  { resource: "user", action: "update", namespace: "core", description: "Update user information" },
  { resource: "user", action: "destroy", namespace: "core", description: "Delete users" },

  # Role management
  { resource: "role", action: "index", namespace: "core", description: "List all roles" },
  { resource: "role", action: "show", namespace: "core", description: "View role details" },
  { resource: "role", action: "create", namespace: "core", description: "Create new roles" },
  { resource: "role", action: "update", namespace: "core", description: "Update roles" },
  { resource: "role", action: "destroy", namespace: "core", description: "Delete roles" },

  # Permission management
  { resource: "permission", action: "index", namespace: "core", description: "List all permissions" },
  { resource: "permission", action: "create", namespace: "core", description: "Create new permissions" },
  { resource: "permission", action: "update", namespace: "core", description: "Update permissions" },
  { resource: "permission", action: "destroy", namespace: "core", description: "Delete permissions" },

  # Event management
  { resource: "event", action: "index", namespace: "core", description: "List all events" },
  { resource: "event", action: "show", namespace: "core", description: "View event details" },
  { resource: "event", action: "create", namespace: "core", description: "Create new events" },
  { resource: "event", action: "update", namespace: "core", description: "Update events" },
  { resource: "event", action: "destroy", namespace: "core", description: "Delete events" },
  { resource: "event", action: "publish", namespace: "core", description: "Publish events" },

  # Ticket management
  { resource: "ticket", action: "index", namespace: "core", description: "List all tickets" },
  { resource: "ticket", action: "show", namespace: "core", description: "View ticket details" },
  { resource: "ticket", action: "create", namespace: "core", description: "Create tickets" },
  { resource: "ticket", action: "update", namespace: "core", description: "Update tickets" },
  { resource: "ticket", action: "destroy", namespace: "core", description: "Delete tickets" },
  { resource: "ticket", action: "scan", namespace: "core", description: "Scan ticket QR codes" },

  # Private attendee exports
  { resource: "attendee_export", action: "request", namespace: "ticketing", description: "Request private attendee exports" },
  { resource: "attendee_export", action: "contact", namespace: "ticketing", description: "Export registration contact fields" },
  { resource: "attendee_export", action: "dietary", namespace: "ticketing", description: "Export dietary fields" },
  { resource: "attendee_export", action: "accessibility", namespace: "ticketing", description: "Export accessibility fields" },

  # Order management
  { resource: "order", action: "index", namespace: "core", description: "List all orders" },
  { resource: "order", action: "show", namespace: "core", description: "View order details" },
  { resource: "order", action: "create", namespace: "core", description: "Create orders" },
  { resource: "order", action: "update", namespace: "core", description: "Update orders" },
  { resource: "order", action: "refund", namespace: "core", description: "Process refunds" },

  # Organization management
  { resource: "organization", action: "index", namespace: "core", description: "List all organizations" },
  { resource: "organization", action: "show", namespace: "core", description: "View organization details" },
  { resource: "organization", action: "create", namespace: "core", description: "Create organizations" },
  { resource: "organization", action: "update", namespace: "core", description: "Update organizations" },
  { resource: "organization", action: "destroy", namespace: "core", description: "Delete organizations" },
  { resource: "organization", action: "manage_memberships", namespace: "core", description: "Manage organization memberships from admin" },
  { resource: "organization", action: "transfer_ownership", namespace: "core", description: "Transfer organization ownership" },

  # Permission management (show — for viewing permission details)
  { resource: "permission", action: "show", namespace: "core", description: "View permission details" },

  # User deactivation/reactivation
  { resource: "user", action: "deactivate", namespace: "core", description: "Deactivate users" },
  { resource: "user", action: "reactivate", namespace: "core", description: "Reactivate users" },

  # Role assignment
  { resource: "user_role", action: "index", namespace: "core", description: "List role assignments" },
  { resource: "user_role", action: "create", namespace: "core", description: "Assign roles to users" },
  { resource: "user_role", action: "destroy", namespace: "core", description: "Remove role assignments" },

  # Audit logs
  { resource: "audit_log", action: "index", namespace: "core", description: "View audit logs" },
  { resource: "audit_log", action: "show", namespace: "core", description: "View audit log details" },

  # Reviews
  { resource: "review", action: "index", namespace: "core", description: "List all reviews" },
  { resource: "review", action: "show", namespace: "core", description: "View review details" },
  { resource: "review", action: "approve", namespace: "core", description: "Approve reviews" },
  { resource: "review", action: "reject", namespace: "core", description: "Reject reviews" },

  # Verifications
  { resource: "verifications", action: "approve", namespace: "admin", description: "Approve organization verifications" },
  { resource: "verifications", action: "reject", namespace: "admin", description: "Reject organization verifications" },
  { resource: "verifications", action: "request_modification", namespace: "admin", description: "Request modification for organization verification" },

  # Venue management
  { resource: "venue", action: "index", namespace: "core", description: "List all venues" },
  { resource: "venue", action: "show", namespace: "core", description: "View venue details" },
  { resource: "venue", action: "create", namespace: "core", description: "Create venues" },
  { resource: "venue", action: "update", namespace: "core", description: "Update venues" },
  { resource: "venue", action: "destroy", namespace: "core", description: "Delete venues" },

  # Artist management
  { resource: "artist", action: "index", namespace: "core", description: "List all artists" },
  { resource: "artist", action: "show", namespace: "core", description: "View artist details" },
  { resource: "artist", action: "create", namespace: "core", description: "Create artists" },
  { resource: "artist", action: "update", namespace: "core", description: "Update artists" },
  { resource: "artist", action: "destroy", namespace: "core", description: "Delete artists" }
]

commercial_permission_actions = %w[
  view draft simulate submit approve activate grant terminate audit budget_view break_glass
].freeze
permissions.concat(commercial_permission_actions.map do |action|
  {
    resource: "commercial",
    action: action,
    namespace: "commercial",
    description: I18n.t("commercial.permissions.#{action}")
  }
end)

permissions << {
  resource: "finance.reserve_policy", action: "update", namespace: "finance",
  description: I18n.t("finance.permissions.reserve_policy_update")
}

permissions.concat([
  { resource: "finance.payout", action: "dispatch", namespace: "finance",
    description: I18n.t("finance.permissions.payout_dispatch") },
  { resource: "finance.payout", action: "reconcile", namespace: "finance",
    description: I18n.t("finance.permissions.payout_reconcile") },
  { resource: "finance.payout", action: "approve_no_balance_api", namespace: "finance",
    description: I18n.t("finance.permissions.payout_approve_no_balance_api") }
])

permissions.each do |perm|
  Core::Permission.find_or_create_by!(resource: perm[:resource], action: perm[:action], namespace: perm[:namespace]) do |p|
    p.description = perm[:description]
    p.active = true
  end
end

puts "✓ #{Core::Permission.count} permissions seeded"

# ─────────────────────────────────────────────
# 4. User Roles (Assign roles to users)
# ─────────────────────────────────────────────
puts "\n🔗 Seeding user roles..."

Core::UserRole.find_or_create_by!(user: admin_user, role: super_admin_role) do |ur|
  ur.assigned_by = admin_user
end

Core::UserRole.find_or_create_by!(user: organizer_user, role: admin_role) do |ur|
  ur.assigned_by = admin_user
end

Core::UserRole.find_or_create_by!(user: organizer_user, role: organizer_role) do |ur|
  ur.assigned_by = admin_user
end

Core::UserRole.find_or_create_by!(user: attendee_user, role: user_role) do |ur|
  ur.assigned_by = admin_user
end

Core::UserRole.find_or_create_by!(user: organizer_user, role: core_admin_role) do |ur|
  ur.assigned_by = admin_user
end

puts "✓ #{Core::UserRole.count} user roles seeded"

# ─────────────────────────────────────────────
# 5. Role Permissions (Assign permissions to roles)
# ─────────────────────────────────────────────
puts "\n🔑 Seeding role permissions..."

# SUPER_ADMIN gets ALL permissions
Core::Permission.active.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: super_admin_role, permission: perm)
end

# ADMIN gets most permissions (except super admin-only)
# Break-glass access is intentionally never inherited from the broad ADMIN role.
admin_permissions = Core::Permission
  .where.not(resource: "permission", action: "destroy")
  .where.not(resource: "commercial", action: "break_glass")
admin_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: admin_role, permission: perm)
end

# ORGANIZER gets event, ticket, order, and organization permissions
organizer_permissions = Core::Permission.where(
  resource: %w[event ticket order organization review],
  namespace: "core"
)
organizer_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: organizer_role, permission: perm)
end

organizer_export_permissions = Core::Permission.where(
  resource: "attendee_export",
  action: %w[request contact],
  namespace: "ticketing"
)
organizer_export_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: organizer_role, permission: perm)
end

# USER gets basic event and ticket viewing permissions
user_permissions = Core::Permission.where(
  resource: %w[event ticket],
  action: %w[index show],
  namespace: "core"
)
user_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: user_role, permission: perm)
end

# CORE_ADMIN gets user/role/permission/user_role/audit_log CRUD (except user.destroy and permission.destroy),
# organization create/update/manage_memberships, and venue/artist CRUD
core_admin_permissions = Core::Permission.where(
  resource: %w[user role permission user_role audit_log venue artist],
  namespace: "core"
).where.not(
  resource: "permission", action: "destroy"
).where.not(
  resource: "user", action: "destroy"
)
core_admin_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: core_admin_role, permission: perm)
end

# Also grant CORE_ADMIN organization index/show/create/update/manage_memberships (but not destroy/transfer_ownership)
core_admin_org_permissions = Core::Permission.where(
  resource: "organization",
  action: %w[index show create update manage_memberships],
  namespace: "core"
)
core_admin_org_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: core_admin_role, permission: perm)
end

# CORE_ADMIN can inspect Commercial definitions; higher-risk actions stay independently assignable.
commercial_view_permission = Core::Permission.find_by!(resource: "commercial", action: "view", namespace: "commercial")
Core::RolePermission.find_or_create_by!(role: core_admin_role, permission: commercial_view_permission)

# SUPPORT gets user index/show/deactivate, role index/show, audit_log index/show,
# and organization index/show
support_permissions = Core::Permission.where(
  resource: %w[user role audit_log],
  action: %w[index show],
  namespace: "core"
).or(
  Core::Permission.where(resource: "user", action: "deactivate", namespace: "core")
).or(
  Core::Permission.where(resource: "organization", action: %w[index show], namespace: "core")
)
support_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: support_role, permission: perm)
end

puts "✓ #{Core::RolePermission.count} role permissions seeded"

# ─────────────────────────────────────────────
# 6. Events::Categories
# ─────────────────────────────────────────────
puts "\n📂 Seeding event categories..."

categories = [
  { name: "Music", description: "Concerts, festivals, and live performances", metadata: { icon: "music-note", color: "#FF5733", display_order: 1 } },
  { name: "Sports", description: "Sporting events, matches, and tournaments", metadata: { icon: "trophy", color: "#33FF57", display_order: 2 } },
  { name: "Conference", description: "Business, tech, and academic conferences", metadata: { icon: "briefcase", color: "#3357FF", display_order: 3 } },
  { name: "Arts & Culture", description: "Exhibitions, theater, dance, and cultural events", metadata: { icon: "palette", color: "#FF33F1", display_order: 4 } },
  { name: "Workshop", description: "Hands-on learning sessions and training", metadata: { icon: "book-open", color: "#FFD733", display_order: 5 } },
  { name: "Networking", description: "Meetups, mixers, and professional networking", metadata: { icon: "users", color: "#33FFF5", display_order: 6 } },
  { name: "Family & Kids", description: "Events for families and children", metadata: { icon: "heart", color: "#FF8333", display_order: 7 } },
  { name: "Food & Drink", description: "Food festivals, tastings, and culinary events", metadata: { icon: "coffee", color: "#8B4513", display_order: 8 } },
  { name: "Charity", description: "Fundraisers, galas, and community service events", metadata: { icon: "gift", color: "#FF3333", display_order: 9 } }
]

categories.each do |cat|
  Events::Category.find_or_create_by!(name: cat[:name]) do |c|
    c.description = cat[:description]
    c.metadata = cat[:metadata]
    c.active = true
  end
end

puts "✓ #{Events::Category.count} event categories seeded"

# ─────────────────────────────────────────────
# 7. Organizations
# ─────────────────────────────────────────────
puts "\n🏢 Seeding organizations..."

org_digis = Organizations::Organization.find_or_create_by!(name: "Digis HQ") do |o|
  o.description = "The official Digis platform organization — manages core platform operations and infrastructure"
  o.organizer_type = "company"
  o.category = "conference"
end

org_music = Organizations::Organization.find_or_create_by!(name: "Addis Music Fest") do |o|
  o.description = "Ethiopia's premier music festival organization — hosts annual concerts and live performances across Addis Ababa"
  o.organizer_type = "company"
  o.category = "music"
end

org_tech = Organizations::Organization.find_or_create_by!(name: "Ethiopian Tech Summit") do |o|
  o.description = "Leading tech conference organizer — brings together innovators, developers, and entrepreneurs from across Africa"
  o.organizer_type = "company"
  o.category = "conference"
end

puts "✓ #{Organizations::Organization.count} organizations seeded"

# The shared seed includes one verified organizer so local and preview checkout
# tests can exercise the real publication and payment-provider gates. The review
# is intentionally marked as a seeded fixture; it is not a substitute for the
# document-backed verification workflow used by real organizers.
chapa_organization_review = org_music.reviews.find_or_initialize_by(context: "verification")
chapa_organization_review.assign_attributes(
  status: "approved",
  feedback: { "source" => "seeded_test_fixture" },
  reviewed_by: nil,
  reviewed_at: Time.current
)
chapa_organization_review.save!
puts "✓ #{org_music.name} marked verified for seeded checkout tests"

# ─────────────────────────────────────────────
# 8. Commercial programs and assignments
# ─────────────────────────────────────────────
puts "\n💼 Seeding commercial program examples..."

commercial_schedule = Commercial::FeeSchedule.find_or_create_by!(code: "first_monetized_event_program") do |schedule|
  schedule.name = "First Monetized Event Program"
  schedule.schedule_type = "program"
  schedule.created_by = admin_user
end

commercial_version = Commercial::FeeScheduleVersion.find_or_create_by!(
  fee_schedule: commercial_schedule, version: 1
) do |version|
  version.status = "draft"
  version.definition_digest = Digest::SHA256.hexdigest("first-monetized-event-program-v1")
  version.acceptance_policy = "none"
end

commercial_program = Commercial::Program.find_or_create_by!(fee_schedule: commercial_schedule) do |program|
  program.program_type = "first_monetized_event"
  program.enrollment_mode = "automatic"
  program.active = true
end

Commercial::Assignment.find_or_create_by!(
  organization: org_music,
  event: nil,
  fee_schedule_version: commercial_version,
  assignment_type: "program"
) do |assignment|
  assignment.program = commercial_program
  assignment.status = "draft"
  assignment.reason = "Seeded first monetized event program"
  assignment.effective_from = Time.zone.parse("2026-01-01 00:00")
  assignment.risk_level = "low"
  assignment.created_by = admin_user
end

puts "✓ #{Commercial::Program.count} programs; #{Commercial::Assignment.count} assignments"

# ─────────────────────────────────────────────
# 9. Memberships
# ─────────────────────────────────────────────
puts "\n👥 Seeding memberships..."

# admin_user owns Digis HQ
Organizations::Membership.find_or_create_by!(user: admin_user, organization: org_digis) do |m|
  m.role = :owner
end

# admin_user is also admin on Music Fest
Organizations::Membership.find_or_create_by!(user: admin_user, organization: org_music) do |m|
  m.role = :admin
end

# organizer_user owns Music Fest
Organizations::Membership.find_or_create_by!(user: organizer_user, organization: org_music) do |m|
  m.role = :owner
end

# organizer_user is member on Tech Summit
Organizations::Membership.find_or_create_by!(user: organizer_user, organization: org_tech) do |m|
  m.role = :staff
end

# attendee_user is member on Digis HQ
Organizations::Membership.find_or_create_by!(user: attendee_user, organization: org_digis) do |m|
  m.role = :staff
end

puts "✓ #{Organizations::Membership.count} memberships seeded"

# ─────────────────────────────────────────────
# 10. Events::Venues
# ─────────────────────────────────────────────
puts "\n🏟️  Seeding venues..."

venues = [
  { name: "Millennium Hall", description: "One of Addis Ababa's largest indoor venues, hosting major concerts, conferences, and cultural events with a capacity of over 5,000.", address: "Bole Road", city: "Addis Ababa", country: "Ethiopia", latitude: 9.0227, longitude: 38.7468, capacity: 5000, contact_phone: "+251911100001", contact_email: "info@millenniumhall.et", website_url: "https://millenniumhall.et", verified: true, active: true, amenities: [ "parking", "air_conditioning", "sound_system", "catering" ] },
  { name: "Sheraton Addis", description: "Luxury hotel and event venue featuring multiple ballrooms and conference facilities in the heart of Addis Ababa.", address: "Yohanis Street", city: "Addis Ababa", country: "Ethiopia", latitude: 9.0247, longitude: 38.7469, capacity: 1500, contact_phone: "+251911100002", contact_email: "events@sheratonaddis.et", website_url: "https://sheratonaddis.et", verified: true, active: true, amenities: [ "parking", "air_conditioning", "wifi", "catering", "stage" ] },
  { name: "Skylight Hotel", description: "Modern convention center and hotel with state-of-the-art facilities for conferences and exhibitions.", address: "Bole International Airport Area", city: "Addis Ababa", country: "Ethiopia", latitude: 8.9806, longitude: 38.7993, capacity: 3000, contact_phone: "+251911100003", contact_email: "info@skylighthotel.et", verified: false, active: true, amenities: [ "parking", "wifi", "catering", "projector" ] }
]

venues.each do |v|
  Events::Venue.find_or_create_by!(name: v[:name]) do |venue|
    venue.assign_attributes(v)
  end
end

puts "✓ #{Events::Venue.count} venues seeded"

# ─────────────────────────────────────────────
# 11. Chapa checkout smoke fixture
# ─────────────────────────────────────────────
puts "\n💳 Seeding Chapa checkout fixture..."

chapa_category = Events::Category.find_by!(name: "Music")
chapa_venue = Events::Venue.find_by!(name: "Millennium Hall")

chapa_event = Events::Event.find_by(title: "Chapa Test Event", organization: org_music)
unless chapa_event
  result = Events::Create.call(
    organization: org_music,
    actor: organizer_user,
    attributes: {
      title: "Chapa Test Event",
      description: "Shared event fixture for Chapa test-mode checkout flows.",
      visibility: "public",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB"
    },
    category_ids: [ chapa_category.id ]
  )
  raise result.error.message unless result.success?

  chapa_event = result.value
end

unless chapa_event.event_categories.exists?
  result = Events::ReplaceCategories.call(
    event: chapa_event,
    category_ids: [ chapa_category.id ],
    actor: organizer_user
  )
  raise result.error.message unless result.success?
end

chapa_event.event_dates.find_or_create_by!(source_key: "chapa-test-date-v1") do |date|
  date.name = "Main performance"
  date.venue = chapa_venue
  date.doors_at = Time.zone.parse("2030-01-15 18:00")
  date.starts_at = Time.zone.parse("2030-01-15 19:00")
  date.ends_at = Time.zone.parse("2030-01-15 22:00")
  date.status = "scheduled"
  date.venue_capacity = chapa_venue.capacity
end

unless chapa_event.event_media.cover.exists?
  cover = chapa_event.event_media.new(
    created_by: organizer_user,
    type: "cover",
    position: 0,
    alt_text: "Chapa test event cover"
  )
  File.open(Rails.root.join("test/fixtures/files/pixel.png")) do |file|
    cover.file.attach(io: file, filename: "chapa-test-event.png", content_type: "image/png")
    cover.save!
    cover.file.blob.analyze
  end
else
  cover = chapa_event.event_media.cover.first
  cover.update!(alt_text: "Chapa test event cover") if cover.alt_text.blank?
  cover.file.blob.analyze unless cover.file.blob.analyzed?
end

unless chapa_event.published?
  result = Events::Publish.call(
    event: chapa_event,
    actor: organizer_user,
    idempotency_key: "seed-chapa-test-event-publish-v1"
  )
  raise result.error.message unless result.success?
end

chapa_product = Catalog::EventProduct.find_by(event: chapa_event, name: "Chapa Test Product")
unless chapa_product
  result = Catalog::Products::CreateDraft.call(
    event: chapa_event,
    actor: organizer_user,
    product_attributes: {
      name: "Chapa Test Product",
      description: "One-unit paid product for Chapa test-mode checkout.",
      type: "other",
      min_per_order: 1,
      max_per_order: 4,
      sales_start_at: Time.zone.parse("2026-01-01 00:00")
    },
    inventory_configuration: { mode: "unlimited" },
    price_attributes: {
      type: "override",
      currency: "ETB",
      amount_minor: 100,
      active_from: Time.zone.parse("2026-01-01 00:00")
    }
  )
  raise result.error.message unless result.success?

  chapa_product = result.value
end

unless chapa_product.status == "active"
  result = Catalog::Products::Activate.call(product: chapa_product, actor: organizer_user)
  raise result.error.message unless result.success?
end

puts "✓ #{chapa_event.title} published with #{chapa_product.name} active at 1 ETB"

# ─────────────────────────────────────────────
# 12. Events::Artists
# ─────────────────────────────────────────────
puts "\n🎤 Seeding artists..."

artists = [
  { name: "Teddy Afro", description: "Ethiopia's biggest musical icon — known for reggae and pop fusion with powerful social commentary", genres: [ "reggae", "pop", "Ethio-jazz" ], image_url: "https://example.com/teddyafro.jpg", verified: true, active: true },
  { name: "Haleluya", description: "Award-winning Ethiopian gospel and contemporary music artist", genres: [ "gospel", "contemporary" ], image_url: "https://example.com/haleluya.jpg", verified: true, active: true },
  { name: "Jano Band", description: "Up-and-coming Ethio-jazz fusion band blending traditional instruments with modern sounds", genres: [ "Ethio-jazz", "fusion", "jazz" ], image_url: "https://example.com/janoband.jpg", verified: false, active: true }
]

artists.each do |a|
  Events::Artist.find_or_create_by!(name: a[:name]) do |artist|
    artist.assign_attributes(a)
  end
end

puts "✓ #{Events::Artist.count} artists seeded"

# ─────────────────────────────────────────────
# 13. Core::Follows (sample follows)
# ─────────────────────────────────────────────
puts "\n❤️  Seeding sample follows..."

attendee = Core::User.find_by(phone: "251911000003")
organizer = Core::User.find_by(phone: "251911000002")

if attendee
  followables = [
    Events::Venue.find_by(name: "Millennium Hall"),
    Events::Artist.find_by(name: "Teddy Afro"),
    Organizations::Organization.find_by(name: "Addis Music Fest")
  ].compact

  followables.each do |f|
    Core::Follow.find_or_create_by!(follower: attendee, followable: f)
  end
  puts "✓ #{Core::Follow.count} follows seeded"
else
  puts "  Skipping follows (attendee user not found)"
end

if organizer
  followable = Events::Artist.find_by(name: "Haleluya")
  Core::Follow.find_or_create_by!(follower: organizer, followable: followable) if followable
end

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
puts "\n" + "=" * 60
puts "🌱 Seeding Complete!"
puts "=" * 60
puts "  Users:              #{Core::User.count}"
puts "  Roles:              #{Core::Role.count}"
puts "  Permissions:        #{Core::Permission.count}"
puts "  User Roles:         #{Core::UserRole.count}"
puts "  Role Permissions:   #{Core::RolePermission.count}"
puts "  Event Categories:   #{Events::Category.count}"
puts "  Organizations:      #{Organizations::Organization.count}"
puts "  Memberships:        #{Organizations::Membership.count}"
puts "  Commercial programs: #{Commercial::Program.count}"
puts "  Commercial assignments: #{Commercial::Assignment.count}"
puts "  Venues:             #{Events::Venue.count}"
puts "  Artists:            #{Events::Artist.count}"
puts "  Follows:            #{Core::Follow.count}"
puts "=" * 60
puts "\n🔑 Default credentials:"
  puts "  Admin:     +251911000001 / password123"
  puts "  Organizer: +251911000002 / password123"
  puts "  Attendee:  +251911000003 / password123"
puts "\n🎭 Admin roles:"
  puts "  SUPER_ADMIN: admin@digis.et"
  puts "  CORE_ADMIN:  organizer@digis.et"
  puts "=" * 60
