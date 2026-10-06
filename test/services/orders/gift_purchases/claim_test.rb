# frozen_string_literal: true

require "test_helper"

module Orders
  module GiftPurchases
    class ClaimTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers
      include Ticketing::ConsentTestHelpers

      setup do
        setup_gift_purchase_context
      end

      test "a bearer recipient completes required form data and receives their paid ticket without OTP" do
        _form, _version, question = create_required_gift_form
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1,
          selected_event_date_id: nil,
          answers: [ { question_key: question.key, value: "Gift recipient" } ],
          consents: []
        )

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission:,
          idempotency_key: "gift-claim-without-otp"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "claimed", @gift_purchase.reload.status
        assert_equal "confirmed", @gift_registration.reload.status
        ticket = result.value.ticket
        assert_equal @gift_purchase.order_item_id, ticket.order_item_id
        assert_equal @gift_registration.id, ticket.registration_id
        assert_equal @gift_purchase.recipient_user_id, ticket.owner_user_id
        assert_not_equal @gift_purchaser.id, ticket.owner_user_id
        credential = ticket.current_credential_generation.credentials.sole
        assert_equal "active", credential.status
        assert_predicate credential.qr_token, :present?
      end

      test "does not create a ticket before required attendee answers are complete" do
        create_required_gift_form
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        )

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission:,
          idempotency_key: "gift-claim-missing-answer"
        )

        assert_predicate result, :failure?
        assert_equal "required_answer", result.error.code
        assert_equal "ready", @gift_purchase.reload.status
        assert_equal "gift_pending_claim", @gift_registration.reload.status
        assert_empty Ticketing::Ticket.where(order_item_id: @gift_order_item.id)
      end

      test "does not complete or issue a gift until its paid order item is fulfilled" do
        @gift_order_item.update_columns(fulfillment_status: "pending")
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        )

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission:,
          idempotency_key: "gift-claim-before-item-fulfillment"
        )

        assert_predicate result, :failure?
        assert_equal "gift_order_not_fulfilled", result.error.code
        assert_equal "gift_pending_claim", @gift_registration.reload.status
        assert_empty Ticketing::Ticket.where(order_item_id: @gift_order_item.id)
      end

      test "does not issue a gift while a refund for its order item is pending" do
        payment = create_gift_payment
        refund = Orders::CreateItemRefund.call(
          payment:,
          order_item: @gift_order_item,
          quantity: 1,
          reason_code: "event_cancellation",
          idempotency_key: "gift-refund-before-claim"
        )
        assert_predicate refund, :success?, refund.error&.message

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
          ),
          idempotency_key: "gift-claim-during-refund"
        )

        assert_predicate result, :failure?
        assert_equal "gift_refund_in_progress", result.error.code
        assert_equal "ready", @gift_purchase.reload.status
        assert_equal "gift_pending_claim", @gift_registration.reload.status
        assert_empty Ticketing::Ticket.where(order_item_id: @gift_order_item.id)
      end

      test "keeps the bearer link claimable until a required admission-slot consent is accepted" do
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        )

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission:,
          idempotency_key: "gift-claim-pending-consent"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending_recipient_consent", result.value.gift_purchase.status
        credential = result.value.ticket.current_credential_generation.credentials.sole
        assert_equal "pending_requirements", credential.status
        assert_nil credential.qr_token
        assert_predicate @gift_registration.consent_requirements.sole, :pending?

        continuation = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1,
            selected_event_date_id: nil,
            answers: [],
            consents: [
              {
                consent_document_version_id: version.id,
                package_unit_number: 1,
                admission_position: 1,
                request_uuid: SecureRandom.uuid,
                acceptance_method: "checkbox",
                content_sha256: version.content_sha256,
                idempotency_key: "gift-slot-consent-acceptance"
              }
            ]
          ),
          idempotency_key: "gift-claim-slot-consent-continuation"
        )

        assert_predicate continuation, :success?, continuation.error&.message
        assert_equal result.value.ticket.id, continuation.value.ticket.id
        assert_equal "claimed", continuation.value.gift_purchase.status
        activated = continuation.value.ticket.current_credential_generation.credentials.sole
        assert_equal "active", activated.status
        assert_predicate activated.qr_token, :present?
        assert_predicate @gift_registration.consent_requirements.sole, :accepted?
      end

      test "accepts a required admission-slot consent during the initial gift claim" do
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        consent = {
          consent_document_version_id: version.id,
          package_unit_number: 1,
          admission_position: 1,
          request_uuid: SecureRandom.uuid,
          acceptance_method: "checkbox",
          content_sha256: version.content_sha256,
          idempotency_key: "gift-slot-consent-initial"
        }

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1, selected_event_date_id: nil, answers: [], consents: [ consent ]
          ),
          idempotency_key: "gift-claim-with-slot-consent"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "claimed", result.value.gift_purchase.status
        assert_equal "active", result.value.ticket.current_credential_generation.credentials.sole.status
      end

      test "requires every required buyer consent before gift claim succeeds" do
        create_consent_document(scope: "buyer", required: true)
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        )

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission:,
          idempotency_key: "gift-claim-missing-buyer-consent"
        )

        assert_predicate result, :failure?
        assert_equal "missing_required_buyer_consent", result.error.code
        assert_equal "ready", @gift_purchase.reload.status
        assert_equal "gift_pending_claim", @gift_registration.reload.status
        assert_empty Ticketing::Ticket.where(order_item_id: @gift_order_item.id)
      end

      test "requires an existing recipient account to authenticate to that account" do
        recipient = @gift_purchase.recipient_user
        recipient.update!(verified_at: Time.current, password: "recipient-password")

        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: nil,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
          ),
          idempotency_key: "gift-claim-needs-login"
        )

        assert_predicate result, :failure?
        assert_equal "gift_recipient_authentication_required", result.error.code
        assert_equal "ready", @gift_purchase.reload.status
      end

      test "rejects an authenticated user other than the intended recipient" do
        result = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          actor: core_users(:support),
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
          ),
          idempotency_key: "gift-claim-wrong-user"
        )

        assert_predicate result, :failure?
        assert_equal "gift_recipient_mismatch", result.error.code
        assert_equal "ready", @gift_purchase.reload.status
      end

      test "replays the exact claim without duplicating registration or ticket" do
        _form, _version, question = create_required_gift_form
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1,
          selected_event_date_id: nil,
          answers: [ { question_key: question.key, value: "Gift recipient" } ],
          consents: []
        )
        subject = -> do
          Claim.call(
            gift_purchase_id: @gift_purchase.id,
            token: @gift_token,
            actor: nil,
            submission:,
            idempotency_key: "gift-claim-replay"
          )
        end

        assert_idempotent(subject, counter: -> { Ticketing::Ticket.where(order_item_id: @gift_order_item.id).count })
        assert_equal 1, Ticketing::RegistrationFormSubmission.where(registration: @gift_registration).count
        reopened = Resolve.call(gift_purchase_id: @gift_purchase.id, token: @gift_token)
        assert_predicate reopened, :success?, reopened.error&.message
        assert_equal @gift_purchase.id, reopened.value.gift.fetch(:id)
        assert_equal 1, Ticketing::Ticket.where(order_item_id: @gift_order_item.id).count
      end

      private

      def create_gift_payment
        Orders::Payment.create!(
          order: @gift_order,
          attempt_number: 1,
          provider: "chapa",
          payment_method: "telebirr",
          status: "succeeded",
          amount_minor: @gift_order.total_minor,
          currency: @gift_order.charge_currency,
          commercial_signature: @gift_order.commercial_signature,
          buyer_fee_minor: 0,
          organizer_fee_minor: 0,
          idempotency_key: "gift-claim-refund-payment-#{SecureRandom.hex(4)}",
          provider_reference: "gift-claim-refund-provider-#{SecureRandom.hex(4)}",
          accepted_at: Time.current,
          succeeded_at: Time.current,
          settlement_grace_minutes: 5,
          settlement_grace_expires_at: @gift_order.expires_at + 5.minutes
        )
      end
    end
  end
end
