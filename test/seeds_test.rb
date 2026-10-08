# frozen_string_literal: true

require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  parallelize(workers: 1)

  setup do
    # The preview profile seeds legal, audit, catalog, and event graphs in
    # addition to users. Reset every test table so repeated seed runs do not
    # collide with audit identities left by an earlier case.
    ActiveRecord::Tasks::DatabaseTasks.truncate_all
  end

  test "preview seed provides an idempotent Chapa checkout fixture" do
    load_seed

    organization = Organizations::Organization.find_by!(name: "Addis Music Fest")
    event = Events::Event.find_by!(title: "Chapa Test Event", organization: organization)
    product = Catalog::EventProduct.find_by!(name: "Chapa Test Product", event: event)

    assert_equal organization.events.count, organization.reload.events_count
    assert organization.verified?
    payout_account = Finance::PayoutAccount.find_by!(organization: organization, provider: "chapa")
    assert_predicate payout_account, :verified?
    assert_predicate payout_account, :is_default?
    assert_equal "test_fixture", payout_account.verification_source
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
    assert Ticketing::RegistrationForm.exists?(event: event, name: "Chapa Attendee Details")

    rsvp_product = Catalog::EventProduct.find_by!(name: "Chapa Test Free RSVP", event: event)
    assert_predicate rsvp_product, :ticket?
    assert_equal "active", rsvp_product.status
    assert_equal "automatic", rsvp_product.ticket_type.approval_mode
    assert_equal "public", rsvp_product.ticket_type.audience
    assert_equal [ 0 ], rsvp_product.prices.active_at(Time.current).pluck(:amount_minor).uniq
    assert rsvp_product.product_accesses.where(event_date: event.event_dates, type: "venue").exists?

    cancellation_event = Events::Event.find_by!(title: "Cancellation Drill Event", organization: organization)
    cancellation_product = Catalog::EventProduct.find_by!(
      name: "Cancellation Drill General Admission", event: cancellation_event
    )
    assert_equal "published", cancellation_event.status
    assert_equal "active", cancellation_product.status
    assert cancellation_product.ticket?
    assert cancellation_product.product_accesses.where(type: "venue").exists?
    assert cancellation_product.product_date_allocations.exists?

    outcomes_event = Events::Event.find_by!(title: "Cancellation Outcomes Drill Event", organization: organization)
    outcomes_product = Catalog::EventProduct.find_by!(
      name: "Cancellation Outcomes General Admission", event: outcomes_event
    )
    assert_equal "published", outcomes_event.status
    assert_equal "active", outcomes_product.status
    assert outcomes_product.ticket?
    assert outcomes_product.product_accesses.where(type: "venue").exists?
    assert outcomes_product.product_date_allocations.exists?

    payment_product = Catalog::EventProduct.find_by!(
      name: "Cancellation Outcomes Payment Unit", event: outcomes_event
    )
    assert_equal "merchandise", payment_product.type
    assert_equal "active", payment_product.status
    assert payment_product.prices.active_at(Time.current).where(currency: "ETB").exists?

    attendee = Core::User.find_by!(email: "attendee@example.com")
    organizer_user = Core::User.find_by!(email: "organizer@digis.et")
    ticket_notification = Messaging::Notification.find_by!(
      user: attendee, notification_type: "ticket_issued"
    )
    assert_equal "delivered", ticket_notification.deliveries.find_by!(channel: "in_app").status
    assert Messaging::Notification.exists?(user: organizer_user, notification_type: "schedule_changed")

    refute Ticketing::ScannerDevice.exists?(device_identifier: "preview-chapa-scanner-001")
    load_seed
    refute Ticketing::ScannerDevice.exists?(device_identifier: "preview-chapa-scanner-001")

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

  test "preview seed repairs a partial Chapa cover fixture" do
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
    previous_profile = ENV["DIGIS_SEED_PROFILE"]
    ENV["DIGIS_SEED_PROFILE"] = "preview"
    Prosopite.pause { load Rails.root.join("db/seeds.rb") }
  ensure
    ENV["DIGIS_SEED_PROFILE"] = previous_profile
  end
end
