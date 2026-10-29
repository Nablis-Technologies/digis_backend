# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Waitlist
    class RequestOtpTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @event.update!(status: "published")
        @actor = core_users(:super_admin)
        @delivered_codes = []
        @previous_sender = Rails.application.config.x.phone_verification_sender
        Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
          @delivered_codes << { phone:, code:, challenge_id: challenge.id }
        end
      end

      teardown do
        Rails.application.config.x.phone_verification_sender = @previous_sender
      end

      test "requests a guest admission OTP for a sold-out paid waitlist offer" do
        product = create_ticket_product(name: "Sold-out paid offer", sold_out: true)

        result = RequestOtp.call(
          event: @event,
          ticket_type: product.ticket_type,
          phone: "+251911000101",
          quantity: 1,
          audience_proof: {},
          idempotency_key: "waitlist-otp-sold-out"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "guest_admission", result.value.challenge.purpose
        assert_equal 1, @delivered_codes.length
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      end

      test "does not send OTP for an available offer" do
        product = create_ticket_product(name: "Available paid offer", sold_out: false)

        result = RequestOtp.call(
          event: @event,
          ticket_type: product.ticket_type,
          phone: "+251911000102",
          quantity: 1,
          audience_proof: {},
          idempotency_key: "waitlist-otp-available"
        )

        assert_predicate result, :failure?
        assert_equal "waitlist_not_sold_out", result.error.code
        assert_empty @delivered_codes
      end

      test "sales end is exclusive for waitlist OTP requests" do
        product = create_ticket_product(name: "Cutoff sold-out offer", sold_out: true)
        cutoff = Time.current.change(usec: 0)
        product.update!(sales_end_at: cutoff)

        travel_to(cutoff) do
          result = RequestOtp.call(
            event: @event,
            ticket_type: product.ticket_type,
            phone: "+251911000104",
            quantity: 1,
            audience_proof: {},
            idempotency_key: "waitlist-otp-cutoff"
          )

          assert_predicate result, :failure?
          assert_equal "waitlist_product_unavailable", result.error.code
          assert_empty @delivered_codes
        end
      end

      test "authorizes gated proof without consuming it before OTP delivery" do
        product = create_ticket_product(name: "Gated sold-out offer", sold_out: true, audience: "access_code")
        raw_code = "WAITLIST-OTP-#{SecureRandom.hex(4)}"
        code = Ticketing::AccessCode.create!(
          ticket_type: product.ticket_type,
          code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: raw_code),
          max_uses: 1,
          max_quantity_per_use: 1,
          active: true,
          code: raw_code
        )

        result = RequestOtp.call(
          event: @event,
          ticket_type: product.ticket_type,
          phone: "+251911000103",
          quantity: 1,
          audience_proof: { access_code: raw_code },
          idempotency_key: "waitlist-otp-gated"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal 0, code.reload.used_count
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      end

      private

      def create_ticket_product(name:, sold_out:, audience: "public")
        result = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name:, type: "ticket" },
          ticket_type_attributes: {
            audience:, approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1,
            waitlist_enabled: true
          },
          price_attributes: { currency: "ETB", amount_minor: 1_500, active_from: 1.minute.ago },
          inventory_configuration: { mode: "event_wide", capacity: 1 }
        )
        assert_predicate result, :success?, result.error&.message
        activated = Catalog::Products::Activate.call(product: result.value, actor: @actor)
        assert_predicate activated, :success?, activated.error&.message
        product = activated.value
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1) if sold_out
        product
      end
    end
  end
end
