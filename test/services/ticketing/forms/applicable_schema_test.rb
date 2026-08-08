# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Forms
    class ApplicableSchemaTest < ActiveSupport::TestCase
      test "returns the published event-wide and product-specific versions" do
        event = events_events(:ready_listing)
        actor = core_users(:super_admin)
        product = Catalog::Products::CreateDraft.call(
          event:,
          actor:,
          product_attributes: { name: "Registration ticket", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value
        ticket_type = product.ticket_type

        event_form = RegistrationForm.create!(event:, name: "General", active: true)
        product_form = RegistrationForm.create!(event:, ticket_type:, name: "Product", active: true)
        event_version = event_form.versions.create!(
          version: 1, status: "published", published_by: actor, published_at: Time.current
        )
        product_version = product_form.versions.create!(
          version: 1, status: "published", published_by: actor, published_at: Time.current
        )

        result = ApplicableSchema.call(event:, ticket_type:)

        assert_predicate result, :success?
        assert_equal [ event_version.id, product_version.id ], result.value.map(&:id)
      end
    end
  end
end
