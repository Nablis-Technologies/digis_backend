# frozen_string_literal: true

require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "canonical seed provides an idempotent Chapa checkout fixture" do
    load_seed

    organization = Organizations::Organization.find_by!(name: "Addis Music Fest")
    event = Events::Event.find_by!(title: "Chapa Test Event", organization: organization)
    product = Catalog::EventProduct.find_by!(name: "Chapa Test Product", event: event)

    assert organization.verified?
    assert_equal "published", event.status
    assert_equal "public", event.visibility
    assert event.event_dates.where(status: "scheduled").exists?
    assert_equal "active", product.status
    assert product.prices.active_at(Time.current).where(currency: "ETB").exists?

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

  private

  # The canonical seed performs many independent reference-data lookups by
  # design; this test verifies data convergence, while domain query tests own
  # N+1 coverage for the application paths exercised by the fixture.
  def load_seed
    Prosopite.pause { load Rails.root.join("db/seeds.rb") }
  end
end
