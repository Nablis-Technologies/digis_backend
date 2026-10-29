# frozen_string_literal: true

require "test_helper"

class PreviewPazimoCatalogTest < ActiveSupport::TestCase
  SOURCE_PATH = Rails.root.join("db/seeds/data/pazimo_events_raw.json")
  SEED_PATH = Rails.root.join("db/seeds/preview_pazimo_catalog.rb")
  REFERENCE_DATE = Date.new(2026, 10, 3)

  test "bundles the source data required by the preview catalog" do
    assert_predicate SOURCE_PATH, :file?, "preview event source JSON must be committed"

    rows = JSON.parse(File.read(SOURCE_PATH, encoding: "UTF-8"))
    assert_operator rows.length, :>=, 30
    first_thirty = rows.first(30)
    assert first_thirty.all? { |row| row["id"].present? && row["title"].present? }
    assert first_thirty.all? { |row| row["start_date"].present? && row["ticket_types"].is_a?(Array) }
  end

  test "projects stable slugs and dates for the first thirty source records" do
    seed = load_seed_class
    assert seed, "PreviewPazimoCatalog seed adapter should be defined"
    return unless seed

    first = seed.records(today: REFERENCE_DATE)
    second = seed.records(today: REFERENCE_DATE)

    assert_equal 30, first.length
    assert_equal first, second
    assert_equal 30, first.map { |record| record.fetch(:slug) }.uniq.length
    assert_equal 4, first.first(4).count { |record| record.fetch(:starts_at).to_date < REFERENCE_DATE }
    assert first.drop(4).all? { |record| record.fetch(:starts_at).to_date > REFERENCE_DATE }
  end

  test "projects source age restrictions into the canonical event setting shape" do
    seed = load_seed_class
    assert seed, "PreviewPazimoCatalog seed adapter should be defined"
    return unless seed

    records = seed.records(today: REFERENCE_DATE)
    source_rows = JSON.parse(File.read(SOURCE_PATH, encoding: "UTF-8")).first(30)
    restricted_source = source_rows.find { |row| row.dig("age_restriction", "has_restriction") == true }
    unrestricted_source = source_rows.find { |row| row.dig("age_restriction", "has_restriction") == false }
    restricted = records.find { |record| record.fetch(:source_id) == restricted_source.fetch("id") }
    unrestricted = records.find { |record| record.fetch(:source_id) == unrestricted_source.fetch("id") }

    assert_equal({ "has_restriction" => true, "min_age" => 21 }, restricted[:age_restriction])
    assert_equal({ "has_restriction" => false }, unrestricted[:age_restriction])
  end

  test "seeds the complete first thirty as public events with ticket offers" do
    seed = load_seed_class
    assert seed, "PreviewPazimoCatalog seed adapter should be defined"
    return unless seed

    records = seed.records(today: REFERENCE_DATE)
    seed_operation = -> { seed.seed!(actor: core_users(:super_admin), records:, attach_covers: false) }
    seeded = defined?(Prosopite) ? Prosopite.pause(&seed_operation) : seed_operation.call

    assert_equal 30, seeded.length
    assert_equal 30, seeded.map(&:slug).uniq.length
    assert seeded.all? { |event| event.status == "published" && event.visibility == "public" }

    event_ids = seeded.map(&:id)
    date_counts = Events::EventDate.where(event_id: event_ids).group(:event_id).count
    assert_equal 30, date_counts.length
    assert date_counts.values.all? { |count| count == 1 }
    products = Catalog::EventProduct.includes(:ticket_type).where(event_id: event_ids).to_a
    assert_equal records.sum { |record| record.fetch(:ticket_tiers).length }, products.length
    assert products.all? { |product| product.ticket? && product.ticket_type.audience == "public" }
    assert_equal products.length, Catalog::ProductPrice.where(event_product_id: products.map(&:id), currency: "ETB").count
    assert_equal products.length, Catalog::ProductInventory.where(event_product_id: products.map(&:id)).count
    assert_equal products.length, Catalog::ProductAccess.where(event_product_id: products.map(&:id), type: "venue").count

    events = Events::Event.includes(:event_dates).where(id: event_ids).to_a
    summaries = Catalog::Public::EventAvailabilitySummary.call(
      events:, at: Time.zone.local(2026, 10, 3, 12)
    )
    assert_equal 30, summaries.length
    assert_includes summaries.values.map { |summary| summary.fetch(:ticket_availability) }, "available"
  end

  test "seeding one event twice is idempotent and leaves existing fixtures intact" do
    seed = load_seed_class
    assert seed, "PreviewPazimoCatalog seed adapter should be defined"
    return unless seed

    existing_event = events_events(:ready_listing)
    existing_product_count = Catalog::EventProduct.where(event: existing_event).count
    initial_event_count = Events::Event.count
    record = seed.records(today: REFERENCE_DATE).first.merge(cover_url: nil)
    actor = core_users(:super_admin)

    first = seed.seed!(actor:, records: [ record ], attach_covers: false).sole
    product = Catalog::EventProduct.includes(:ticket_type).where(event: first).sole
    assert_equal "public", product.ticket_type.audience
    assert_equal record.fetch(:ticket_tiers).first.fetch(:amount_minor), product.prices.base.for_currency("ETB").sole.amount_minor
    setting = first.event_setting
    assert setting, "seed should create an event setting"
    return unless setting

    assert_equal record[:age_restriction], setting.age_restriction
    setting.update!(config: setting.config.merge("seed_test_sibling" => "preserve"))
    products_after_first = Catalog::EventProduct.where(event: first).count
    prices_after_first = Catalog::ProductPrice.joins(:event_product)
      .where(catalog_event_products: { event_id: first.id }).count
    inventories_after_first = Catalog::ProductInventory.joins(:event_product)
      .where(catalog_event_products: { event_id: first.id }).count
    accesses_after_first = Catalog::ProductAccess.joins(:event_product)
      .where(catalog_event_products: { event_id: first.id }).count

    updated_record = record.merge(age_restriction: { "has_restriction" => false })
    replay = seed.seed!(actor:, records: [ updated_record ], attach_covers: false).sole

    assert_equal first.id, replay.id
    assert_equal({ "has_restriction" => false }, setting.reload.age_restriction)
    assert_equal "preserve", setting.config.fetch("seed_test_sibling")
    assert_equal initial_event_count + 1, Events::Event.count
    assert_equal products_after_first, Catalog::EventProduct.where(event: first).count
    assert_equal prices_after_first, Catalog::ProductPrice.joins(:event_product)
      .where(catalog_event_products: { event_id: first.id }).count
    assert_equal inventories_after_first, Catalog::ProductInventory.joins(:event_product)
      .where(catalog_event_products: { event_id: first.id }).count
    assert_equal accesses_after_first, Catalog::ProductAccess.joins(:event_product)
      .where(catalog_event_products: { event_id: first.id }).count
    assert_equal existing_product_count, Catalog::EventProduct.where(event: existing_event).count
    assert Events::Event.exists?(id: existing_event.id)
  end

  private

  def load_seed_class
    return unless SOURCE_PATH.file? && SEED_PATH.file?

    require SEED_PATH.to_s
    return unless Object.const_defined?(:PreviewPazimoCatalog, false)

    PreviewPazimoCatalog
  end
end
