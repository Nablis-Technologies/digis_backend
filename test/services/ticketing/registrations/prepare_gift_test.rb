# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class PrepareGiftTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @purchaser = core_users(:attendee)
        @ticket_type = create_ticket_type
      end

      test "creates a recipient-owned pending registration without requiring OTP or attendee answers" do
        result = prepare(phone: "0911000091", key: "gift-registration-create")

        assert_predicate result, :success?, result.error&.message
        registration = result.value
        recipient = Core::User.find_by!(phone: "+251911000091")
        assert_equal recipient, registration.user
        assert_equal @purchaser, registration.created_by
        assert_equal "gift_pending_claim", registration.status
        assert_equal 64, registration.identity_digest.length
        assert_empty registration.form_submissions
        assert_empty registration.consent_requirements
        assert_nil recipient.verified_at
        assert_nil recipient.password_digest
      end

      test "resolves an existing recipient account without changing its profile" do
        recipient = core_users(:support)
        profile = recipient.slice(:email, :phone, :verified_at, :password_digest)

        result = prepare(phone: recipient.phone, key: "gift-registration-existing-account")

        assert_predicate result, :success?, result.error&.message
        assert_equal recipient, result.value.user
        assert_equal profile, recipient.reload.slice(:email, :phone, :verified_at, :password_digest)
      end

      test "replays the same recipient registration and conflicts if the recipient changes" do
        first = prepare(phone: "0911000092", key: "gift-registration-replay")
        replay = prepare(phone: "0911000092", key: "gift-registration-replay")
        changed = prepare(phone: "0911000093", key: "gift-registration-replay")

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
        assert_predicate changed, :failure?
        assert_equal "idempotency_conflict", changed.error.code
        assert_nil Core::User.find_by(phone: "+251911000093")
      end

      test "rejects audience-gated offers before creating a recipient identity" do
        @ticket_type.update!(audience: "access_code")

        result = prepare(phone: "0911000094", key: "gift-registration-private-offer")

        assert_predicate result, :failure?
        assert_equal "gift_offer_unsupported", result.error.code
        assert_nil Core::User.find_by(phone: "+251911000094")
        assert_equal 0, Registration.count
      end

      test "rejects manual-approval offers before creating a recipient identity" do
        @ticket_type.update!(approval_mode: "manual")

        result = prepare(phone: "0911000095", key: "gift-registration-manual-offer")

        assert_predicate result, :failure?
        assert_equal "gift_offer_unsupported", result.error.code
        assert_nil Core::User.find_by(phone: "+251911000095")
        assert_equal 0, Registration.count
      end

      test "rejects waitlist-enabled offers before creating a recipient identity" do
        @ticket_type.update!(waitlist_enabled: true)

        result = prepare(phone: "0911000096", key: "gift-registration-waitlist-offer")

        assert_predicate result, :failure?
        assert_equal "gift_offer_unsupported", result.error.code
        assert_nil Core::User.find_by(phone: "+251911000096")
        assert_equal 0, Registration.count
      end

      private

      def prepare(phone:, key:)
        PrepareGift.call(
          ticket_type: @ticket_type,
          purchaser: @purchaser,
          recipient_phone: phone,
          package_quantity: 1,
          selected_event_date_id: nil,
          idempotency_key: key
        )
      end

      def create_ticket_type
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Gift admission #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, waitlist_enabled: false
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
      end
    end
  end
end
