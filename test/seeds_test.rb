# frozen_string_literal: true

require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  parallelize(workers: 1)

  setup do
    # Seed verification needs a clean user namespace, while the surrounding
    # suite loads fixture users with intentionally different email mappings.
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE core_users CASCADE")
  end

  test "canonical seed provides an idempotent Chapa checkout fixture" do
    load_seed

    organization = Organizations::Organization.find_by!(name: "Addis Music Fest")
    event = Events::Event.find_by!(title: "Chapa Test Event", organization: organization)
    product = Catalog::EventProduct.find_by!(name: "Chapa Test Product", event: event)

    assert organization.verified?
    assert_equal "+251911000001", Core::User.find_by!(email: "admin@digis.et").phone
    assert_equal "+251900123456", Core::User.find_by!(email: "chapa.test@gmail.com").phone
    assert_equal "published", event.status
    assert_equal "public", event.visibility
    assert event.event_dates.where(status: "scheduled").exists?
    assert_equal "active", product.status
    assert product.prices.active_at(Time.current).where(currency: "ETB").exists?

    ticket_product = Catalog::EventProduct.find_by!(name: "Chapa Test General Admission", event: event)
    assert ticket_product.ticket?
    assert_equal "active", ticket_product.status
    assert ticket_product.ticket_type
    assert ticket_product.product_accesses.where(type: "venue").exists?
    assert ticket_product.product_date_allocations.exists?

    quote = Orders::BuildQuote.call(
      event: event,
      buyer: Core::User.find_by!(email: "attendee@example.com"),
      items: [ { product_id: product.id, quantity: 1 } ],
      charge_currency: "ETB",
      provider: "chapa",
      payment_method: "telebirr"
    )
    assert quote.success?, quote.error&.message

    counts = [
      Organizations::Organization.where(name: organization.name).count,
      Events::Event.where(id: event.id).count,
      Catalog::EventProduct.where(id: product.id).count,
      Core::Review.where(reviewable: organization, context: "verification").count
    ]

    load_seed

    assert_equal counts, [
      Organizations::Organization.where(name: organization.name).count,
      Events::Event.where(id: event.id).count,
      Catalog::EventProduct.where(id: product.id).count,
      Core::Review.where(reviewable: organization, context: "verification").count
    ]
  end

  test "canonical seed repairs a partial Chapa cover fixture" do
    load_seed

    event = Events::Event.find_by!(title: "Chapa Test Event")
    cover = event.event_media.cover.first
    cover.file.blob.update!(metadata: cover.file.blob.metadata.except("analyzed", "seed_fixture"))

    load_seed

    assert_equal "chapa-test-event-cover-v1:local", cover.reload.file.blob.metadata.fetch("seed_fixture")
  end

  private

  # The canonical seed performs many independent reference-data lookups by
  # design; this test verifies data convergence, while domain query tests own
  # N+1 coverage for the application paths exercised by the fixture.
  def load_seed
    Prosopite.pause { load Rails.root.join("db/seeds.rb") }
  end
end
