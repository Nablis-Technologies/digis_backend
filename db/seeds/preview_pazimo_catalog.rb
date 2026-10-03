# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "json"
require "open-uri"
require "uri"

# Additive catalog fixtures sourced from the public event snapshot. This seed
# deliberately does not remove other preview events or transaction history.
module PreviewPazimoCatalog
  SOURCE_PATH = Rails.root.join("db/seeds/data/pazimo_events_raw.json")
  EVENT_LIMIT = 30
  PAST_EVENT_SAMPLE = 4
  EVENT_DATE_SOURCE_PREFIX = "pazimo-preview:"
  MAX_COVER_SIZE = 4.megabytes
  ALLOWED_IMAGE_HOST = "pazimo.com"

  CATEGORY_NAMES = {
    "Music" => "Music",
    "Festivals" => "Music",
    "Tech" => "Conference",
    "Arts" => "Arts & Culture",
    "Art" => "Arts & Culture",
    "Sports" => "Sports"
  }.freeze

  IMAGE_CONTENT_TYPES = {
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }.freeze

  def self.records(today: Time.zone.today)
    source_rows = JSON.parse(File.read(SOURCE_PATH, encoding: "UTF-8"))
    validate_source!(source_rows)

    source_rows.first(EVENT_LIMIT).each_with_index.map do |source, index|
      record_for(source, index:, today:)
    end
  end

  def self.seed!(actor:, records: nil, attach_covers: true)
    source_records = records || self.records
    source_records.map do |record|
      seed_event!(record, actor:, attach_covers:)
    end
  end

  def self.validate_source!(source_rows)
    unless source_rows.is_a?(Array) && source_rows.length >= EVENT_LIMIT
      raise "Pazimo preview source must contain at least #{EVENT_LIMIT} event records"
    end

    ids = source_rows.first(EVENT_LIMIT).map { |row| row["id"].to_s }
    return if ids.all?(&:present?) && ids.uniq.length == EVENT_LIMIT

    raise "Pazimo preview source requires unique, non-blank IDs for its first #{EVENT_LIMIT} events"
  end
  private_class_method :validate_source!

  def self.record_for(source, index:, today:)
    source_id = source.fetch("id").to_s
    source_start_date = Date.iso8601(source.fetch("start_date"))
    start_date = preview_date(source_start_date, index:, source_id:, today:)
    end_date = preview_end_date(source, source_start_date, start_date)
    starts_at = parse_clock(start_date, source["start_time"], default: "19:00")
    ends_at = parse_clock(end_date, source["end_time"], default: "22:00")
    ends_at += 1.day while ends_at <= starts_at

    {
      source_id:,
      slug: slug_for(source, source_id),
      title: source.fetch("title").to_s.strip,
      description: source["description"].to_s,
      category: CATEGORY_NAMES[source["category"]],
      organizer_name: source.fetch("organizer").to_s.strip,
      city: normalize_city(source["city"]),
      country: source["country"].to_s.strip.presence || "Ethiopia",
      venue_name: venue_name(source["address"]),
      starts_at:,
      ends_at:,
      venue_capacity: source["capacity"].to_i,
      cover_url: Array(source["images"]).first,
      ticket_tiers: ticket_tiers(source)
    }
  end
  private_class_method :record_for

  def self.preview_date(source_date, index:, source_id:, today:)
    offset = Digest::SHA256.hexdigest(source_id).first(8).to_i(16)
    if index < PAST_EVENT_SAMPLE
      source_date < today ? source_date : today - 5 - (offset % 26)
    else
      source_date > today ? source_date : today + 7 + (offset % 54)
    end
  end
  private_class_method :preview_date

  def self.preview_end_date(source, source_start_date, start_date)
    source_end_date = Date.iso8601(source.fetch("end_date"))
    start_date + [ (source_end_date - source_start_date).to_i, 0 ].max
  rescue Date::Error
    start_date
  end
  private_class_method :preview_end_date

  def self.parse_clock(date, clock, default:)
    parsed = Time.zone.parse("#{date.iso8601} #{clock.presence || default}")
    parsed || Time.zone.parse("#{date.iso8601} #{default}")
  rescue ArgumentError
    Time.zone.parse("#{date.iso8601} #{default}")
  end
  private_class_method :parse_clock

  def self.slug_for(source, source_id)
    base = source["slug"].to_s.parameterize.presence || source.fetch("title").to_s.parameterize
    "pazimo-#{base}-#{source_id.last(8)}"
  end
  private_class_method :slug_for

  def self.ticket_tiers(source)
    Array(source["ticket_types"]).first(5).each_with_index.map do |tier, index|
      quantity = [ tier["quantity"].to_i, 0 ].max
      sellable = tier["available"] == true && quantity.positive? && source["sold_out"] != true
      {
        name: tier["name"].to_s.strip.presence || "Ticket #{index + 1}",
        description: tier["description"].to_s,
        amount_minor: amount_minor(tier["price_etb"]),
        quantity:,
        sellable:
      }
    end
  end
  private_class_method :ticket_tiers

  def self.amount_minor(value)
    (BigDecimal(value.to_s) * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
  rescue ArgumentError
    0
  end
  private_class_method :amount_minor

  def self.normalize_city(value)
    value.to_s.strip.gsub(/\bAddis Abeba\b/i, "Addis Ababa").presence
  end
  private_class_method :normalize_city

  def self.venue_name(address)
    name = address.to_s.split(",", 2).first.to_s.split("|", 2).first.to_s.strip
    name.presence unless name.casecmp("TBA").zero?
  end
  private_class_method :venue_name

  def self.seed_event!(record, actor:, attach_covers:)
    organization = find_or_create_organization(record.fetch(:organizer_name))
    event = Events::Event.find_or_initialize_by(slug: record.fetch(:slug))
    if event.new_record?
      event.assign_attributes(
        organization:,
        created_by: actor,
        title: record.fetch(:title),
        description: record.fetch(:description),
        status: "published",
        visibility: "public",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        published_at: Time.current
      )
      event.save!
    end

    seed_category!(event, record[:category])
    venue = find_or_create_venue(record)
    event_date = seed_event_date!(event, record, venue)
    seed_products!(event, event_date, record)
    attach_cover!(event, actor, record[:cover_url]) if attach_covers
    event
  end
  private_class_method :seed_event!

  def self.find_or_create_organization(name)
    Organizations::Organization.find_or_create_by!(name:) do |organization|
      organization.organizer_type = "company"
      organization.category = "other"
      organization.events_count = 0
      organization.followers_count = 0
    end
  end
  private_class_method :find_or_create_organization

  def self.seed_category!(event, source_category)
    return if source_category.blank?

    category = Events::Category.find_by(name: source_category)
    event.categories = [ category ] if category && event.categories.ids != [ category.id ]
  end
  private_class_method :seed_category!

  def self.find_or_create_venue(record)
    return if record[:venue_name].blank?

    venue = Events::Venue.find_by("LOWER(name) = ?", record[:venue_name].downcase)
    return venue if venue

    Events::Venue.create!(
      name: record[:venue_name],
      city: record[:city],
      country: record[:country],
      followers_count: 0
    )
  end
  private_class_method :find_or_create_venue

  def self.seed_event_date!(event, record, venue)
    date = event.event_dates.find_or_initialize_by(source_key: "#{EVENT_DATE_SOURCE_PREFIX}#{record[:source_id]}")
    return date if date.persisted?

    date.assign_attributes(
      name: "#{record[:title]} performance",
      venue:,
      starts_at: record[:starts_at],
      ends_at: record[:ends_at],
      status: "scheduled",
      venue_capacity: record[:venue_capacity].positive? ? record[:venue_capacity] : nil
    )
    date.save!
    date
  end
  private_class_method :seed_event_date!

  def self.seed_products!(event, event_date, record)
    ensure_venue_zone!(event)
    record.fetch(:ticket_tiers).each do |tier|
      product = seed_ticket_product!(event, tier)
      seed_price!(product, tier, record[:starts_at])
      seed_inventory!(product, tier, record[:venue_capacity])
      seed_access!(product, event_date)
    end
  end
  private_class_method :seed_products!

  def self.seed_ticket_product!(event, tier)
    product = event.event_products.find_or_initialize_by(name: tier[:name], type: "ticket")
    return product if product.persisted?

    product.assign_attributes(
      description: tier[:description],
      status: "active",
      inventory_mode: "event_wide",
      schedule_change_refund_policy: "full_or_partial",
      min_per_order: 1,
      max_per_order: 6,
      metadata: {}
    )
    product.build_ticket_type(
      approval_mode: "automatic",
      audience: "public",
      date_selection: "fixed",
      delegation_validation_mode: "offline_allowed",
      entry_validation_mode: "qr",
      transfer_cutoff_seconds_before_start: 0,
      admissions_per_unit: 1,
      resale_cutoff_seconds_before_start: 0,
      max_completed_resales: 1,
      transferable: false,
      resale_enabled: false
    )
    product.save!
    product.ticket_type.save! if product.ticket_type&.new_record?
    product
  end
  private_class_method :seed_ticket_product!

  def self.seed_price!(product, tier, starts_at)
    return if product.prices.base.for_currency("ETB").exists?

    product.prices.create!(
      currency: "ETB",
      amount_minor: tier[:amount_minor],
      type: "base",
      active_from: starts_at - 365.days
    )
  end
  private_class_method :seed_price!

  def self.seed_inventory!(product, tier, event_capacity)
    return if product.inventories.where(event_date_id: nil).exists?

    capacity = if tier[:sellable]
      tier[:quantity]
    else
      [ event_capacity, tier[:quantity], 1 ].max
    end
    sold_count = tier[:sellable] ? 0 : capacity
    product.inventories.create!(capacity:, sold_count:, held_count: 0)
  end
  private_class_method :seed_inventory!

  def self.seed_access!(product, event_date)
    access = product.product_accesses.find_or_initialize_by(event_date:, type: "venue")
    if access.new_record?
      access.usage_limit = 1
      access.save!
    end

    zone = Events::AccessZone.find_or_create_by!(event: product.event, code: "MAIN", type: "venue") do |row|
      row.name = "Main Entrance"
      row.sort_order = 0
      row.active = true
    end
    access.product_access_zones.find_or_create_by!(access_zone: zone)
    product.product_date_allocations.find_or_create_by!(event_date:) do |allocation|
      allocation.allocation_basis_points = 10_000
    end
  end
  private_class_method :seed_access!

  def self.ensure_venue_zone!(event)
    Events::AccessZone.find_or_create_by!(event:, code: "MAIN", type: "venue") do |zone|
      zone.name = "Main Entrance"
      zone.sort_order = 0
      zone.active = true
    end
  end
  private_class_method :ensure_venue_zone!

  def self.attach_cover!(event, actor, url)
    return if url.blank? || event.event_media.cover.exists?

    uri = URI.parse(url)
    return unless uri.scheme == "https" && allowed_image_host?(uri.host)

    remote = URI.open(uri.to_s, open_timeout: 5, read_timeout: 10)
    return if remote.size > MAX_COVER_SIZE || !allowed_image_host?(remote.base_uri.host)

    filename = File.basename(uri.path)
    content_type = IMAGE_CONTENT_TYPES[File.extname(filename).downcase]
    return unless content_type

    media = event.event_media.new(
      created_by: actor,
      type: "cover",
      position: 0,
      alt_text: event.title
    )
    remote.rewind
    media.file.attach(io: remote, filename:, content_type:)
    media.save!
  rescue StandardError => error
    warn "Skipped Pazimo cover for #{event.slug} (#{error.class})"
  ensure
    remote&.close
  end
  private_class_method :attach_cover!

  def self.allowed_image_host?(host)
    host == ALLOWED_IMAGE_HOST || host.to_s.end_with?(".#{ALLOWED_IMAGE_HOST}")
  end
  private_class_method :allowed_image_host?
end
