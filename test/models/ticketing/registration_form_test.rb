# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationFormTest < ActiveSupport::TestCase
    test "rejects a product form whose ticket type belongs to another event" do
      event = events_events(:ready_listing)
      other_event = events_events(:draft_concert)
      product = Catalog::EventProduct.new(event: other_event, name: "Other", type: "ticket")
      ticket_type = Ticketing::TicketType.new(event_product: product)
      form = RegistrationForm.new(event:, ticket_type:, name: "Attendee details", active: true)

      assert_not form.valid?
      assert form.errors.key?(:ticket_type)
    end

    test "allows an event-wide form without a ticket type" do
      form = RegistrationForm.new(
        event: events_events(:ready_listing),
        name: "Attendee details",
        active: true
      )

      assert form.valid?
    end
  end
end
