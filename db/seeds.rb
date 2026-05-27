# This file should ensure the existence of records required to run the application in every environment.
# The code here is idempotent — safe to run multiple times without duplicating data.
#
# Load with: bin/rails db:seed

puts "=" * 60
puts "🌱 Digis Backend — Seeding Database"
puts "=" * 60

# ─────────────────────────────────────────────
# 1. Core Users
# ─────────────────────────────────────────────
puts "\n👤 Seeding users..."

admin_user = Core::User.find_or_create_by!(phone: "+251911000001") do |u|
  u.email = "admin@digis.et"
  u.password = "password123"
  u.verified_at = Time.current
end

organizer_user = Core::User.find_or_create_by!(phone: "+251911000002") do |u|
  u.email = "organizer@digis.et"
  u.password = "password123"
  u.verified_at = Time.current
end

attendee_user = Core::User.find_or_create_by!(phone: "+251911000003") do |u|
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
  { resource: "review", action: "reject", namespace: "core", description: "Reject reviews" }
]

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
admin_permissions = Core::Permission.where.not(resource: "permission", action: "destroy")
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

# USER gets basic event and ticket viewing permissions
user_permissions = Core::Permission.where(
  resource: %w[event ticket],
  action: %w[index show],
  namespace: "core"
)
user_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: user_role, permission: perm)
end

# CORE_ADMIN gets all user/role/permission/user_role CRUD (except user.destroy and permission.destroy)
core_admin_permissions = Core::Permission.where(
  resource: %w[user role permission user_role audit_log],
  namespace: "core"
).where.not(
  resource: "permission", action: "destroy"
).where.not(
  resource: "user", action: "destroy"
)
core_admin_permissions.find_each do |perm|
  Core::RolePermission.find_or_create_by!(role: core_admin_role, permission: perm)
end

# SUPPORT gets user index/show/deactivate, role index, audit_log index/show
support_permissions = Core::Permission.where(
  resource: %w[user role audit_log],
  action: %w[index show],
  namespace: "core"
).or(
  Core::Permission.where(resource: "user", action: "deactivate", namespace: "core")
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
end

org_music = Organizations::Organization.find_or_create_by!(name: "Addis Music Fest") do |o|
  o.description = "Ethiopia's premier music festival organization — hosts annual concerts and live performances across Addis Ababa"
end

org_tech = Organizations::Organization.find_or_create_by!(name: "Ethiopian Tech Summit") do |o|
  o.description = "Leading tech conference organizer — brings together innovators, developers, and entrepreneurs from across Africa"
end

puts "✓ #{Organizations::Organization.count} organizations seeded"

# ─────────────────────────────────────────────
# 8. Memberships
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
  m.role = :member
end

# attendee_user is member on Digis HQ
Organizations::Membership.find_or_create_by!(user: attendee_user, organization: org_digis) do |m|
  m.role = :member
end

puts "✓ #{Organizations::Membership.count} memberships seeded"

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
puts "=" * 60
puts "\n🔑 Default credentials:"
  puts "  Admin:     +251911000001 / password123"
  puts "  Organizer: +251911000002 / password123"
  puts "  Attendee:  +251911000003 / password123"
puts "\n🎭 Admin roles:"
  puts "  SUPER_ADMIN: admin@digis.et"
  puts "  CORE_ADMIN:  organizer@digis.et"
  puts "=" * 60
