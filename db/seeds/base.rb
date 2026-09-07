# Production-safe seed base. Keep only reference data and bootstrap access here.
# Preview and development fixtures are loaded by db/seeds.rb profiles.

puts "=" * 60
puts "🌱 Digis Backend — Seeding Database"
puts "=" * 60

# Seed users with the canonical Ethiopian international phone format.
def seed_user(phone:, email:, password:)
  user = Core::User.find_or_initialize_by(phone: phone)
  user.assign_attributes(email: email, password: password, verified_at: Time.current)
  user.save!
  user
end

# 1. Core Users
# ─────────────────────────────────────────────
puts "\n👤 Seeding users..."

admin_user = seed_user(phone: "+251911000001", email: "admin@digis.et", password: "password123")

puts "✓ #{Core::User.count} users seeded"

# Notification payloads are derived user-facing data, not business audit rows.
# Keep the retention policy in the production-safe reference seed so every
# environment calculates the same erase deadline before a notification is
# created.
notification_policy_scope = Core::DataRetentionPolicy.where(
  category: "messaging_notification", jurisdiction_code: nil
)
notification_policy = notification_policy_scope.active.first
unless notification_policy
  version = notification_policy_scope.maximum(:version).to_i
  notification_policy = notification_policy_scope.find_by(version: version) if version.positive?
  notification_policy = notification_policy_scope.new(version: version + 1) if notification_policy&.status == "retired"
  notification_policy ||= notification_policy_scope.new(version: [ version, 1 ].max)
  notification_policy.assign_attributes(
    retention_days: 365,
    action: "erase_payload",
    status: "active",
    effective_at: 1.day.ago,
    created_by: admin_user
  )
  notification_policy.save!
end

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
    description: I18n.t("finance.permissions.payout_approve_no_balance_api") },
  { resource: "finance.payout_account", action: "verify", namespace: "finance",
    description: I18n.t("finance.permissions.payout_account_verify") }
])

permissions.concat([
  { resource: "messaging_credit_account", action: "index", namespace: "messaging", description: "View messaging credit balances" },
  { resource: "messaging_credit_account", action: "show", namespace: "messaging", description: "View a messaging credit account" },
  { resource: "messaging_credit_top_up", action: "create", namespace: "messaging", description: "Purchase messaging credits" },
  { resource: "messaging_credit_top_up", action: "show", namespace: "messaging", description: "View a messaging credit top-up" },
  { resource: "messaging_credit_rate", action: "index", namespace: "messaging", description: "View messaging credit rates" },
  { resource: "messaging_credit_rate", action: "show", namespace: "messaging", description: "View a messaging credit rate" },
  { resource: "messaging_credit_rate", action: "create", namespace: "messaging", description: "Create messaging credit rates" },
  { resource: "messaging_credit_rate", action: "activate", namespace: "messaging", description: "Activate messaging credit rates" },
  { resource: "messaging_credit_rate", action: "retire", namespace: "messaging", description: "Retire messaging credit rates" },
  { resource: "messaging_credit_adjustment", action: "create", namespace: "messaging", description: "Adjust messaging credits" },
  { resource: "messaging_campaign", action: "index", namespace: "messaging", description: "Inspect messaging campaigns" },
  { resource: "messaging_campaign", action: "show", namespace: "messaging", description: "Inspect a messaging campaign" },
  { resource: "messaging_campaign_template", action: "index", namespace: "messaging", description: "List campaign templates" },
  { resource: "messaging_campaign_template", action: "show", namespace: "messaging", description: "View a campaign template" },
  { resource: "messaging_campaign_template", action: "create", namespace: "messaging", description: "Create a campaign template" },
  { resource: "messaging_campaign_template", action: "update", namespace: "messaging", description: "Update a campaign template" },
  { resource: "messaging_campaign_volume_policy", action: "index", namespace: "messaging", description: "List campaign volume policies" },
  { resource: "messaging_campaign_volume_policy", action: "show", namespace: "messaging", description: "View a campaign volume policy" },
  { resource: "messaging_campaign_volume_policy", action: "update", namespace: "messaging", description: "Update a campaign volume policy" }
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

[
  [ "messaging_credit_account", %w[index show] ],
  [ "messaging_credit_top_up", %w[create show] ],
  [ "messaging_credit_rate", %w[index show] ]
].each do |resource, actions|
  Core::Permission.where(resource:, action: actions, namespace: "messaging").find_each do |perm|
    Core::RolePermission.find_or_create_by!(role: organizer_role, permission: perm)
  end
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
