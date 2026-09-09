# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Rsvps
    class SubmitTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @event.update!(status: "published")
        @attendee = core_users(:attendee)
        @ticket_type = create_rsvp_ticket_type
        @delivered_codes = []
        @previous_sender = Rails.application.config.x.phone_verification_sender
        Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
          @delivered_codes << { phone:, code:, challenge_id: challenge.id }
        end
      end

      teardown do
        Rails.application.config.x.phone_verification_sender = @previous_sender
      end

      test "automatic free RSVP confirms and issues one ticket" do
        result = submit(ticket_type: @ticket_type, actor: @attendee, key: "rsvp-service-auto")

        assert_predicate result, :success?, result.error&.message
        assert_equal "confirmed", result.value.registration.status
        assert_equal "confirmed", result.value.next_action
        assert_equal :created, result.value.status
        assert_equal 1, result.value.tickets.count
      end

      test "manual free RSVP remains pending approval without a ticket" do
        manual_type = create_rsvp_ticket_type(approval_mode: "manual")

        result = submit(ticket_type: manual_type, actor: @attendee, key: "rsvp-service-manual")

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending_approval", result.value.registration.status
        assert_equal "awaiting_approval", result.value.next_action
        assert_equal :accepted, result.value.status
        assert_empty result.value.tickets
      end

      test "guest RSVP requires a verified guest_rsvp proof" do
        phone = "+251911000061"
        requested = RequestOtp.call(
          event: @event, ticket_type: @ticket_type, phone:, idempotency_key: "rsvp-otp-submit-1"
        )
        assert_predicate requested, :success?, requested.error&.message
        verified = Core::PhoneVerification::Verify.call(
          challenge: requested.value.challenge, code: @delivered_codes.last.fetch(:code)
        )
        assert_predicate verified, :success?, verified.error&.message

        result = submit(
          ticket_type: @ticket_type,
          actor: nil,
          phone:,
          verification_token: verified.value.token,
          key: "rsvp-service-guest"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal phone, result.value.registration.user.phone
        assert_equal "confirmed", result.value.registration.status
      end

      test "rejects a registered account through the guest path" do
        requested = RequestOtp.call(
          event: @event,
          ticket_type: @ticket_type,
          phone: @attendee.phone,
          idempotency_key: "rsvp-otp-submit-registered"
        )
        assert_predicate requested, :failure?
        assert_equal "guest_requires_authentication", requested.error.code
      end

      test "replays a confirmed registration without reconfirming or duplicating tickets" do
        subject = -> { submit(ticket_type: @ticket_type, actor: @attendee, key: "rsvp-service-replay") }

        assert_idempotent(
          subject,
          counter: -> { Ticketing::Ticket.count }
        )
        replay = subject.call
        assert_equal 1, Registration.where(ticket_type: @ticket_type).count
        assert_equal :ok, replay.value.status
        assert_equal "confirmed", replay.value.next_action
        assert_equal 1, replay.value.tickets.count
      end

      test "returns issuing for a confirmed replay when a ticket unit is missing" do
        no_access_type = create_rsvp_ticket_type(with_access: false)
        first = submit(ticket_type: no_access_type, actor: @attendee, key: "rsvp-service-issuing")

        assert_predicate first, :success?, first.error&.message
        assert_equal :accepted, first.value.status
        assert_equal "issuing", first.value.next_action
        assert_equal "confirmed", first.value.registration.status
        assert Core::OutboxEvent.exists?(
          event_type: "ticketing.registration.issuance_ready",
          aggregate_id: first.value.registration.id
        )

        replay = submit(ticket_type: no_access_type, actor: @attendee, key: "rsvp-service-issuing")
        assert_predicate replay, :success?, replay.error&.message
        assert_equal :accepted, replay.value.status
        assert_equal "issuing", replay.value.next_action
        assert_equal 0, replay.value.tickets.count
      end

      test "rolls back a new registration when capacity reservation fails" do
        limited_type = create_rsvp_ticket_type(inventory_mode: "event_wide", capacity: 1)
        first = submit(ticket_type: limited_type, actor: @attendee, key: "rsvp-service-capacity-1")
        assert_predicate first, :success?, first.error&.message

        before = Registration.where(ticket_type: limited_type).count
        result = submit(ticket_type: limited_type, actor: core_users(:support), key: "rsvp-service-capacity-2")

        assert_predicate result, :failure?
        assert_equal before, Registration.where(ticket_type: limited_type).count
      end

      test "rejects quantities above the synchronous issuance bound" do
        result = submit(ticket_type: @ticket_type, actor: @attendee, quantity: 11, key: "rsvp-service-bound")

        assert_predicate result, :failure?
        assert_equal "rsvp_quantity_invalid", result.error.code
      end

      test "issues ten packages without an unbounded request" do
        result = submit(ticket_type: @ticket_type, actor: @attendee, quantity: 10, key: "rsvp-service-ten")

        assert_predicate result, :success?, result.error&.message
        assert_equal 10, result.value.tickets.count
      end

      private

      def submit(ticket_type:, actor:, phone: actor&.phone, verification_token: nil, quantity: 1, key:)
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: quantity,
          selected_event_date_id: nil,
          answers: [],
          consents: []
        )
        Submit.call(
          event: @event,
          ticket_type:,
          actor:,
          phone:,
          verification_token:,
          submission:,
          idempotency_key: key
        )
      end

      def create_rsvp_ticket_type(approval_mode: "automatic", amount_minor: 0,
        inventory_mode: "unlimited", capacity: nil, with_access: true)
        inventory_configuration = { mode: inventory_mode }
        inventory_configuration[:capacity] = capacity if capacity
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "RSVP submit #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode:, date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { type: "base", currency: "ETB", amount_minor:, active_from: 1.minute.ago },
          inventory_configuration:
        )
        assert_predicate product, :success?, product.error&.message
        if with_access
          date = @event.event_dates.create!(
            name: "RSVP submit date #{SecureRandom.hex(3)}",
            starts_at: 1.day.from_now,
            ends_at: 1.day.from_now + 2.hours,
            status: "scheduled"
          )
          product.value.product_accesses.create!(event_date: date, type: "venue")
        end
        activated = Catalog::Products::Activate.call(
          product: product.value, actor: core_users(:super_admin)
        )
        assert_predicate activated, :success?, activated.error&.message
        activated.value.ticket_type
      end
    end
  end
end
