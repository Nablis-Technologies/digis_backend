# frozen_string_literal: true

# ─────────────────────────────────────────────────────────────────────────────
# Dev / API-test seed — COMPLETE fixture for this branch.
#
# Covers every model + endpoint from Plan 1 (Tasks 1–6, event-foundation)
# and the Legal module. Idempotent — safe to run repeatedly, and meant to
# be EXTENDED as new endpoints/models land: add a section, reuse the
# find_or_create_by + publish-service patterns already used below.
#
# Load with EITHER:
#   bin/rails runner db/seeds/dev.rb
#   bin/rails db:seed:dev          # (see lib/tasks/seeds.rake)
#
# Auth for API tests:
#   POST /core/auth/login  { phone: "+251911000001", password: "password123" }
#   → use the returned token as  Authorization: Bearer <token>
# ─────────────────────────────────────────────────────────────────────────────

require "base64"
require "stringio"

puts "=" * 60
puts "🧪 Digis Backend — Dev / API-test seed"
puts "=" * 60

# A real 1x1 white JPEG (ActiveStorage validates the bytes via Marcel).
JPEG_B64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k="

def dev_image(filename: "seed.jpg", content_type: "image/jpeg")
  StringIO.new(Base64.decode64(JPEG_B64)).tap { |io| io.rewind }
        .then { |io| { io: io, filename: filename, content_type: content_type } }
end

# Stable, valid UUID (Postgres uuid columns reject non-UUID strings).
# Deterministic from a seed so re-runs are idempotent.
def stable_uuid(seed)
  hex = Digest::SHA256.hexdigest(seed)
  [ hex[0, 8], hex[8, 4], "4#{hex[12, 3]}", "8#{hex[16, 3]}", hex[20, 12] ].join("-")
end

# ─────────────────────────────────────────────
# 1. Users + Super Admin role (reuses main seed credentials)
# ─────────────────────────────────────────────
puts "\n👤 Ensuring users + roles..."

admin = Core::User.find_or_create_by!(phone: "+251911000001") do |u|
  u.email = "admin@digis.et"
  u.password = "password123"
  u.verified_at = Time.current
end

organizer = Core::User.find_or_create_by!(phone: "+251911000002") do |u|
  u.email = "organizer@digis.et"
  u.password = "password123"
  u.verified_at = Time.current
end

attendee = Core::User.find_or_create_by!(phone: "+251911000003") do |u|
  u.email = "attendee@example.com"
  u.password = "password123"
  u.verified_at = Time.current
end

staff_user = Core::User.find_or_create_by!(phone: "+251911000009") do |u|
  u.email = "staff@example.com"
  u.password = "password123"
  u.verified_at = Time.current
end

super_admin_role = Core::Role.find_or_create_by!(code: "SUPER_ADMIN") do |r|
  r.name = "Super Admin"
  r.active = true
end

Core::UserRole.find_or_create_by!(user: admin, role: super_admin_role) do |ur|
  ur.assigned_by = admin
end

puts "✓ #{Core::User.count} users; admin is SUPER_ADMIN"

# ─────────────────────────────────────────────
# 2. Reference data: categories, venues, artists
# ─────────────────────────────────────────────
puts "\n🗂  Seeding reference data (categories / venues / artists)..."

%w[Music Sports Conference Comedy Theater Festival Workshop Exhibition Other].each do |name|
  Events::Category.find_or_create_by!(name: name)
end

[
  { name: "Millennium Hall", city: "Addis Ababa" },
  { name: "Grand Hole", city: "Bahir Dar" }
].each do |attrs|
  Events::Venue.find_or_create_by!(name: attrs[:name]) do |v|
    v.city = attrs[:city]
    v.followers_count = 0
  end
end

[
  { name: "Teddy Afro", genres: %w[ethio-pop] },
  { name: "Haleluya", genres: %w[gospel contemporary] }
].each do |attrs|
  Events::Artist.find_or_create_by!(name: attrs[:name]) do |a|
    a.genres = attrs[:genres]
    a.followers_count = 0
  end
end

venue    = Events::Venue.find_by(name: "Millennium Hall")
artist   = Events::Artist.find_by(name: "Teddy Afro")

puts "✓ #{Events::Category.count} categories, #{Events::Venue.count} venues, #{Events::Artist.count} artists"

# ─────────────────────────────────────────────
# 3. Organizations (+ owner memberships, used by verification endpoints)
# ─────────────────────────────────────────────
puts "\n🏢 Seeding organizations..."

def seed_organization(name:, organizer_type:, category:, owner:)
  org = Organizations::Organization.find_or_create_by!(name: name) do |o|
    o.organizer_type = organizer_type
    o.category = category
    o.events_count = 0
    o.followers_count = 0
  end
  Organizations::Membership.find_or_create_by!(user: owner, organization: org) do |m|
    m.role = :owner
    m.status = :active
  end
  org
end

digis_hq = seed_organization(name: "Digis HQ", organizer_type: "company",
                              category: "music", owner: admin)
fest_org = seed_organization(name: "Addis Music Fest", organizer_type: "company",
                              category: "festival", owner: organizer)
dev_org  = seed_organization(name: "Dev Test Organizer", organizer_type: "company",
                              category: "conference", owner: admin)

puts "✓ #{Organizations::Organization.count} organizations"

# ─────────────────────────────────────────────
# 4. Events + all nested resources (Plan 1, Tasks 1–6)
# ─────────────────────────────────────────────
puts "\n🎫 Seeding events + nested resources..."

fest_event = Events::Event.find_or_create_by!(title: "Addis Music Fest 2026", organization: fest_org) do |e|
  e.created_by = admin
  e.status = "published"
  e.visibility = "public"
  e.timezone = "Africa/Addis_Ababa"
  e.currency = "ETB"
end

dev_event = Events::Event.find_or_create_by!(title: "Dev Test Event", organization: dev_org) do |e|
  e.created_by = admin
  e.status = "draft"
  e.visibility = "private"
  e.timezone = "Africa/Addis_Ababa"
  e.currency = "ETB"
end

# --- EventOrganizations (co-organizer) ---
Events::EventOrganization.find_or_create_by!(event: fest_event, organization: digis_hq) do |eo|
  eo.type = "co_organizer"
  eo.status = "active"
  eo.role = "partner"
end

# --- EventStaffAssignments ---
Events::EventStaffAssignment.find_or_create_by!(event: fest_event, user: admin, role: "manager") do |s|
  s.organization = fest_org
  s.status = "active"
end
Events::EventStaffAssignment.find_or_create_by!(event: fest_event, user: staff_user, role: "staff") do |s|
  s.organization = fest_org
  s.status = "active"
end

# --- EventDates (fixed timestamps so re-runs are idempotent) ---
fest_date = Events::EventDate.find_or_create_by!(
  event: fest_event, starts_at: Time.zone.parse("2026-08-01 19:00")
) do |d|
  d.ends_at = Time.zone.parse("2026-08-01 23:00")
  d.status = "scheduled"
  d.held_venue_count = 0
  d.issued_venue_count = 0
end

# --- EventParticipants ---
Events::EventParticipant.find_or_create_by!(event: fest_event, name: "Teddy Afro", type: "performer") do |p|
  p.display_order = 0
end

# --- AccessZones ---
Events::AccessZone.find_or_create_by!(event: fest_event, code: "MAIN") do |z|
  z.name = "Main Gate"
  z.type = "venue"
  z.sort_order = 0
end

# --- RecurrenceRule ---
Events::RecurrenceRule.find_or_create_by!(event: fest_event) do |r|
  r.rrule = "FREQ=WEEKLY;BYDAY=MO"
  r.timezone = "Africa/Addis_Ababa"
  r.dtstart_local = "2026-08-01T19:00:00"
  r.duration_seconds = 14_400
end

# --- EventMedia (requires attached image) ---
# NOTE: attach on an already-persisted record re-saves and trips the
# `file_attached?` validation, so build with new + attach + save!.
unless fest_event.event_media.where(type: "cover").exists?
  cover = fest_event.event_media.new(created_by: admin, type: "cover", position: 0)
  cover.file.attach(**dev_image(filename: "cover.jpg"))
  cover.save!
end
unless fest_event.event_media.where(type: "gallery").exists?
  gallery = fest_event.event_media.new(created_by: admin, type: "gallery", position: 1)
  gallery.file.attach(**dev_image(filename: "gallery.jpg"))
  gallery.save!
end

# --- EventVideoLinks ---
Events::EventVideoLink.find_or_create_by!(event: fest_event, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") do |v|
  v.created_by = admin
  v.provider = "youtube"
  v.position = 0
end

# --- ConsentDocuments (Plan 1, Task 6) + published version ---
[
  { type: "terms", name: "Event Terms", body: "You consent to the event terms and conditions." },
  { type: "liability_waiver", name: "Liability Waiver", body: "You waive liability as stated." }
].each do |spec|
  doc = Events::ConsentDocument.find_or_create_by!(
    event: fest_event, type: spec[:type], name: spec[:name]
  ) do |c|
    c.active = true
    c.created_by = admin
  end

  next if doc.versions.any?

  doc.versions.create!(
    version: 1, status: "draft",
    title: spec[:name], body: spec[:body],
    content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
      type: spec[:type], title: spec[:name], body: spec[:body]
    ),
    required: true, acceptance_scope: "buyer", created_by: admin
  )
  Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: admin)
end

# Dev event also gets one consent document (for the owner endpoints / testing)
dev_consent = Events::ConsentDocument.find_or_create_by!(
  event: dev_event, type: "terms", name: "Dev Event Terms"
) do |c|
  c.active = true
  c.created_by = admin
end
unless dev_consent.versions.any?
  dev_consent.versions.create!(
    version: 1, status: "draft",
    title: "Dev Event Terms", body: "Dev event terms.",
    content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
      type: "terms", title: "Dev Event Terms", body: "Dev event terms."
    ),
    required: true, acceptance_scope: "buyer", created_by: admin
  )
  Events::ConsentDocuments::PublishVersion.call(consent_document: dev_consent, actor: admin)
end

puts "✓ #{Events::Event.count} events; " \
     "#{Events::EventOrganization.count} event-orgs, " \
     "#{Events::EventStaffAssignment.count} staff, " \
     "#{Events::EventDate.count} dates, " \
     "#{Events::EventParticipant.count} participants, " \
     "#{Events::AccessZone.count} zones, " \
     "#{Events::RecurrenceRule.count} recurrence rules, " \
     "#{Events::EventMedia.count} media, " \
     "#{Events::EventVideoLink.count} video links, " \
     "#{Events::ConsentDocument.count} consent docs"

# ─────────────────────────────────────────────
# 5. Legal module (this branch) — docs, versions, acceptances
# ─────────────────────────────────────────────
puts "\n⚖️  Seeding legal documents..."

LEGAL_DOCS = [
  { document_type: "platform_terms",        internal_name: "Platform Terms of Service", body: "By using Digis you agree to the platform terms." },
  { document_type: "privacy_policy",         internal_name: "Privacy Policy",               body: "We collect and process your data as described here." },
  { document_type: "organizer_agreement",    internal_name: "Organizer Agreement",          body: "Organizers agree to the platform organizer terms." },
  { document_type: "organizer_fee_schedule", internal_name: "Organizer Fee Schedule",       body: "Platform fee is 10% per ticket sold.", commercial_policy_reference: "FEE-2026-GLOBAL-10PCT" },
  { document_type: "buyer_purchase_terms",   internal_name: "Buyer Purchase Terms",         body: "Buyers agree to the purchase terms." }
].freeze

LEGAL_DOCS.each do |spec|
  doc = Legal::LegalDocument.find_or_create_by!(
    document_type: spec[:document_type], jurisdiction_code: "GLOBAL", locale: "en"
  ) do |d|
    d.internal_name = spec[:internal_name]
    d.created_by = admin
  end

  next if doc.versions.any?

  doc.versions.create!(
    version: 1, status: "draft",
    title: spec[:internal_name], body: spec[:body],
    content_sha256: Legal::LegalDocumentVersion.content_sha256_for(title: spec[:internal_name], body: spec[:body]),
    commercial_policy_reference: spec[:commercial_policy_reference],
    created_by: admin
  )
  Legal::PublishVersion.call(legal_document: doc, actor: admin)
end

# Record acceptances for the admin user on every published version
# (idempotent via a deterministic valid UUID per doc type).
Legal::LegalDocumentVersion.published.each do |version|
  Legal::RecordAcceptance.call(
    subject: admin,
    legal_document_version: version,
    accepted_by: admin,
    request_uuid: stable_uuid("dev-accept-#{version.legal_document.document_type}")
  )
end

puts "✓ #{Legal::LegalDocument.count} legal documents; " \
     "#{Legal::LegalDocumentVersion.published.count} published; " \
     "#{Legal::LegalAcceptance.count} acceptances"

# ─────────────────────────────────────────────
# 6. Follows (Core::Follow) — for follow/unfollow endpoints
# ─────────────────────────────────────────────
puts "\n❤️  Seeding follows..."

[venue, artist, dev_org].compact.each do |followable|
  Core::Follow.find_or_create_by!(follower: attendee, followable: followable)
end

puts "✓ #{Core::Follow.count} follows"

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
puts "\n" + "=" * 60
puts "🧪 Dev seed complete!"
puts "=" * 60
puts "  Users (SUPER_ADMIN): #{Core::User.count}"
puts "  Organizations:      #{Organizations::Organization.count}"
puts "  Events:            #{Events::Event.count}"
puts "  Consent docs:      #{Events::ConsentDocument.count} (#{Events::ConsentDocumentVersion.published.count} published)"
puts "  Legal docs:        #{Legal::LegalDocument.count} (#{Legal::LegalDocumentVersion.published.count} published)"
puts "  Legal acceptances: #{Legal::LegalAcceptance.count}"
puts "\n🔑 Auth (POST /core/auth/login):"
puts "  Admin:     +251911000001 / password123"
puts "  Organizer: +251911000002 / password123"
puts "  Attendee:  +251911000003 / password123"
puts "\n📡 Try:"
puts "  GET  /events                              (events index)"
puts "  GET  /events/:id/event_dates            (nested resources)"
puts "  GET  /admin/legal_documents             (as Admin)"
puts "  POST /admin/legal_documents/:id/publish"
puts "  GET  /events/:id/consent_documents"
puts "  GET  /organizations/owner              (owner orgs)"
puts "=" * 60
