# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Waitlist
    class SubmitTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @event.update!(status: "published")
        @actor = core_users(:super_admin)
        @buyer = core_users(:attendee)
      end

      test "enrolls an eligible authenticated registration only after sold-out validation" do
        product = create_ticket_product(name: "Sold-out offer", capacity: 1)
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)

        result = call_submit(product:, key: "waitlist-submit-sold-out")

        assert_predicate result, :success?, result.error&.message
        registration = result.value.registration
        assert_equal "waitlisted", registration.status
        assert_equal "waitlisted", result.value.next_action
      end

      test "rejects joining while an offer still has inventory without creating a registration" do
        product = create_ticket_product(name: "Available offer", capacity: 1)

        result = call_submit(product:, key: "waitlist-submit-available")

        assert_predicate result, :failure?
        assert_equal "waitlist_not_sold_out", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      end

      test "sales end is exclusive for waitlist submissions" do
        product = create_ticket_product(name: "Cutoff waitlist offer", capacity: 1)
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)
        cutoff = Time.current.change(usec: 0)
        product.update!(sales_end_at: cutoff)

        travel_to(cutoff) do
          result = call_submit(product:, key: "waitlist-submit-cutoff")

          assert_predicate result, :failure?
          assert_equal "waitlist_product_unavailable", result.error.code
          assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        end
      end

      test "rejects a sold-out choose-one offer after its event date has started" do
        past_date = @event.event_dates.create!(
          starts_at: 2.hours.ago, ends_at: 1.hour.ago, status: "scheduled"
        )
        product = create_ticket_product(
          name: "Past choose-one offer", capacity: 1,
          date_selection: "choose_one", event_dates: [ past_date ]
        )
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)

        result = call_submit(
          product:, key: "waitlist-submit-past-date", selected_event_date_id: past_date.id
        )

        assert_predicate result, :failure?
        assert_equal "waitlist_product_unavailable", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      end

      test "manual approval creates a pending approval without queue enrollment" do
        product = create_ticket_product(name: "Reviewed sold-out offer", capacity: 1, approval_mode: "manual")
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)

        result = call_submit(product:, key: "waitlist-submit-manual")

        assert_predicate result, :success?, result.error&.message
        assert_equal "awaiting_approval", result.value.next_action
        assert_equal "pending_approval", result.value.registration.status
        assert_nil result.value.registration.waitlisted_at
      end

      test "replay does not duplicate enrollment or consume an access code twice" do
        product = create_ticket_product(
          name: "Gated sold-out offer", capacity: 1, audience: "access_code"
        )
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)
        raw_code = "WAITLIST-#{SecureRandom.hex(5)}"
        code = Ticketing::AccessCode.create!(
          ticket_type: product.ticket_type,
          code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: raw_code),
          max_uses: 2,
          max_quantity_per_use: 1,
          active: true,
          code: raw_code
        )
        request = lambda do
          call_submit(
            product:,
            key: "waitlist-submit-replay",
            proof: { access_code: raw_code }
          )
        end

        assert_idempotent(request, counter: -> { Ticketing::Registration.where(ticket_type: product.ticket_type).count })
        assert_equal 1, code.reload.used_count
      end

      private

      def call_submit(product:, key:, proof: {}, selected_event_date_id: nil)
        operation = lambda do
          Submit.call(
            event: @event,
            ticket_type: product.ticket_type,
            actor: @buyer,
            submission: Ticketing::RegistrationSubmission.new(
              package_quantity: 1, selected_event_date_id:, answers: [], consents: []
            ),
            audience_proof: proof,
            idempotency_key: key
          )
        end
        ENV["N_PLUS_ONE"] == "1" ? Prosopite.pause(&operation) : operation.call
      end

      def create_ticket_product(name:, capacity:, audience: "public", approval_mode: "automatic",
        date_selection: "fixed", event_dates: [])
        result = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name:, type: "ticket" },
          ticket_type_attributes: {
            audience:, approval_mode:, date_selection:, admissions_per_unit: 1,
            waitlist_enabled: true
          },
          price_attributes: { currency: "ETB", amount_minor: 1_500, active_from: 1.minute.ago },
          inventory_configuration: { mode: "event_wide", capacity: }
        )
        assert_predicate result, :success?, result.error&.message
        event_dates.each do |date|
          result.value.product_accesses.create!(event_date: date, type: "venue", usage_limit: nil)
        end
        activated = Catalog::Products::Activate.call(product: result.value, actor: @actor)
        assert_predicate activated, :success?, activated.error&.message
        activated.value
      end
    end
  end
end
