# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Rsvps
    class RequestOtpTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @event.update!(status: "published")
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

      test "creates one guest_rsvp challenge for a valid public free product" do
        result = RequestOtp.call(
          event: @event,
          ticket_type: @ticket_type,
          phone: "+251911000051",
          idempotency_key: "rsvp-otp-service-1"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending", result.value.challenge.status
        assert_equal 1, Core::PhoneVerificationChallenge.where(purpose: "guest_rsvp").count
        assert_equal "+251911000051", @delivered_codes.first.fetch(:phone)
      end

      test "replaying the same key returns the original challenge without redelivery" do
        subject = -> do
          RequestOtp.call(
            event: @event,
            ticket_type: @ticket_type,
            phone: "+251911000052",
            idempotency_key: "rsvp-otp-service-2"
          )
        end

        assert_idempotent(
          subject,
          counter: -> { Core::PhoneVerificationChallenge.where(purpose: "guest_rsvp").count }
        )
        assert_equal 1, @delivered_codes.length
      end

      test "rejects a registered account before creating or sending an OTP" do
        result = RequestOtp.call(
          event: @event,
          ticket_type: @ticket_type,
          phone: core_users(:attendee).phone,
          idempotency_key: "rsvp-otp-service-registered"
        )

        assert_predicate result, :failure?
        assert_equal "guest_requires_authentication", result.error.code
        assert_empty @delivered_codes
        assert_empty Core::PhoneVerificationChallenge.where(purpose: "guest_rsvp")
      end

      test "rejects a ticket type whose product belongs to another event" do
        other_event = events_events(:draft_concert)
        other_event.update!(status: "published")

        result = RequestOtp.call(
          event: other_event,
          ticket_type: @ticket_type,
          phone: "+251911000053",
          idempotency_key: "rsvp-otp-service-cross-event"
        )

        assert_predicate result, :failure?
        assert_equal "rsvp_product_not_found", result.error.code
        assert_empty @delivered_codes
      end

      test "rejects a paid product" do
        paid_type = create_rsvp_ticket_type(amount_minor: 100)

        result = RequestOtp.call(
          event: @event,
          ticket_type: paid_type,
          phone: "+251911000054",
          idempotency_key: "rsvp-otp-service-paid"
        )

        assert_predicate result, :failure?
        assert_equal "rsvp_paid_product_requires_checkout", result.error.code
        assert_empty @delivered_codes
      end

      test "rejects a product without an active price before sending an OTP" do
        @ticket_type.event_product.prices.update_all(active_from: 1.day.from_now)

        result = RequestOtp.call(
          event: @event,
          ticket_type: @ticket_type,
          phone: "+251911000055",
          idempotency_key: "rsvp-otp-service-no-active-price"
        )

        assert_predicate result, :failure?
        assert_equal "rsvp_product_not_found", result.error.code
        assert_empty @delivered_codes
      end

      private

      def create_rsvp_ticket_type(amount_minor: 0)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "RSVP service #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { type: "base", currency: "ETB", amount_minor:, active_from: 1.minute.ago },
          inventory_configuration: { mode: "unlimited" }
        )
        assert_predicate product, :success?, product.error&.message
        date = @event.event_dates.create!(
          name: "RSVP service date #{SecureRandom.hex(3)}",
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 2.hours,
          status: "scheduled"
        )
        product.value.product_accesses.create!(event_date: date, type: "venue")
        activated = Catalog::Products::Activate.call(
          product: product.value, actor: core_users(:super_admin)
        )
        assert_predicate activated, :success?, activated.error&.message
        activated.value.ticket_type
      end
    end
  end
end
