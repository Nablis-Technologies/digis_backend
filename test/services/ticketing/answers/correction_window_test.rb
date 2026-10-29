# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Answers
    class CorrectionWindowTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
      end

      test "fixed ticket cutoff uses earliest non-cancelled product access date" do
        product = create_ticket_product(date_selection: "fixed")
        cancelled = create_date(starts_at: 1.day.from_now, status: "cancelled")
        earliest = create_date(starts_at: 3.days.from_now)
        later = create_date(starts_at: 5.days.from_now)
        [ cancelled, earliest, later ].each { |date| add_access(product, date) }
        registration = create_registration(product:)

        assert defined?(CorrectionWindow), "Ticketing::Answers::CorrectionWindow should be implemented"
        assert_equal earliest.starts_at - 3_600.seconds, CorrectionWindow.call(registration:)
      end

      test "returns no cutoff when neither product access nor event has a schedule" do
        event = Events::Event.create!(
          organization: @event.organization,
          created_by: @actor,
          title: "Unscheduled answer event",
          slug: "unscheduled-answer-#{SecureRandom.hex(4)}",
          status: "published",
          visibility: "public",
          timezone: "Africa/Addis_Ababa",
          currency: "ETB"
        )
        product = create_ticket_product(date_selection: "fixed", event:)
        registration = create_registration(product:, event:)

        assert_nil CorrectionWindow.call(registration:)
      end

      test "choose-one cutoff uses the registration selected date" do
        product = create_ticket_product(date_selection: "choose_one")
        earlier = create_date(starts_at: 2.days.from_now)
        selected = create_date(starts_at: 4.days.from_now)
        [ earlier, selected ].each { |date| add_access(product, date) }
        registration = create_registration(product:, selected_event_date: selected)

        assert defined?(CorrectionWindow), "Ticketing::Answers::CorrectionWindow should be implemented"
        assert_equal selected.starts_at - 3_600.seconds, CorrectionWindow.call(registration:)
      end

      private

      def create_ticket_product(date_selection:, event: @event)
        Catalog::Products::CreateDraft.call(
          event:,
          actor: @actor,
          product_attributes: { name: "Answer cutoff #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection:,
            admissions_per_unit: 1, transfer_cutoff_seconds_before_start: 3_600
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type.event_product
      end

      def create_date(starts_at:, status: "scheduled")
        @event.event_dates.create!(starts_at:, ends_at: starts_at + 2.hours, status:)
      end

      def add_access(product, date)
        product.product_accesses.create!(event_date: date, type: "venue", usage_limit: nil)
      end

      def create_registration(product:, selected_event_date: nil, event: @event)
        Ticketing::Registration.create!(
          event:,
          ticket_type: product.ticket_type,
          user: core_users(:attendee),
          created_by: core_users(:attendee),
          selected_event_date:,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: Time.current
        )
      end
    end
  end
end
