# frozen_string_literal: true

require "test_helper"

module Orders
  module GiftPurchases
    class ExpireTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers
      include Ticketing::ConsentTestHelpers

      setup do
        setup_gift_purchase_context
      end

      test "expires an unused gift and releases the recipient purchase-limit allocation without refunding" do
        allocation = committed_purchase_limit_allocation

        result = Expire.call(gift_purchase: @gift_purchase, at: @gift_purchase.expires_at)

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", @gift_purchase.reload.status
        assert_equal "expired", @gift_registration.reload.status
        assert_equal "released", allocation.reload.status
        assert_equal "expired", allocation.release_reason
        assert_empty Ticketing::Ticket.where(order_item_id: @gift_order_item.id)
        assert_empty Orders::Refund.where(payment: @gift_order.payments)
      end

      test "expires a claimed link at event end without revoking the recipient ticket" do
        _form, _version, question = create_required_gift_form
        claim = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1,
            selected_event_date_id: nil,
            answers: [ { question_key: question.key, value: "Recipient" } ],
            consents: []
          ),
          idempotency_key: "expire-claimed-gift"
        )
        assert_predicate claim, :success?, claim.error&.message

        result = Expire.call(gift_purchase: @gift_purchase, at: @gift_purchase.expires_at)

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", @gift_purchase.reload.status
        assert_equal "confirmed", @gift_registration.reload.status
        assert_equal "active", claim.value.ticket.reload.status
      end

      test "expires an incomplete consent claim, revokes its placeholder ticket, and releases limits" do
        _buyer_document, buyer_version = create_consent_document(scope: "buyer", required: true)
        _slot_document, slot_version = create_consent_document(scope: "admission_slot", required: true)
        claim = Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1,
            selected_event_date_id: nil,
            answers: [],
            consents: [
              {
                consent_document_version_id: buyer_version.id,
                request_uuid: SecureRandom.uuid,
                acceptance_method: "checkbox",
                content_sha256: buyer_version.content_sha256,
                idempotency_key: "expire-gift-buyer-consent"
              }
            ]
          ),
          idempotency_key: "expire-pending-consent-gift"
        )
        assert_predicate claim, :success?, claim.error&.message
        allocation = committed_purchase_limit_allocation
        ticket = claim.value.ticket
        generation = ticket.current_credential_generation
        credential = generation.credentials.sole
        buyer_requirement = @gift_registration.consent_requirements.find_by!(
          consent_document_version_id: buyer_version.id
        )
        slot_requirement = @gift_registration.consent_requirements.find_by!(
          consent_document_version_id: slot_version.id
        )
        assert_equal "accepted", buyer_requirement.status
        assert_equal "pending", slot_requirement.status
        assert_equal "pending_requirements", credential.status
        suspension = Ticketing::Suspensions::Open.call(
          ticket:,
          actor: core_users(:super_admin),
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "pending-gift-expiry-suspension"
        ).value

        result = Expire.call(gift_purchase: @gift_purchase, at: @gift_purchase.expires_at)

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", @gift_purchase.reload.status
        assert_equal "confirmed", @gift_registration.reload.status
        assert_equal "active", ticket.reload.status
        expiry_event = Core::OutboxEvent.find_by!(
          topic: "ticketing",
          event_type: "ticketing.gift_claim.expired",
          aggregate_id: @gift_registration.id
        )
        assert_equal @gift_registration.id, expiry_event.payload.fetch("registration_id")
        assert_equal ticket.id, expiry_event.payload.fetch("ticket_id")
        assert_equal @gift_purchase.expires_at.iso8601(6), expiry_event.payload.fetch("expires_at")

        dispatch = Core::Outbox::Dispatch.call(event_id: expiry_event.id)

        assert_predicate dispatch, :success?
        assert_equal "expired", @gift_registration.reload.status
        assert_equal "accepted", buyer_requirement.reload.status
        assert_equal "expired", slot_requirement.reload.status
        assert_equal @gift_purchase.expires_at, slot_requirement.expired_at
        assert_equal 0, Ticketing::ConsentReminderJob.perform_now
        assert_equal "void", ticket.reload.status
        assert_equal "revoked", generation.reload.status
        assert_equal "revoked", credential.reload.status
        assert ticket.revocation.reload.is_dead
        assert_not ticket.revocation.is_suspended
        assert_equal "released", allocation.reload.status
        assert_equal "expired", suspension.reload.status
        assert_equal "gift_claim_expired", suspension.resolution_reason
        assert_nil suspension.resolved_by_id
        assert_empty Orders::Refund.joins(:refund_items).where(
          orders_refund_items: { order_item_id: @gift_order_item.id }
        )
      end

      test "is idempotent when the expiry worker replays the same gift" do
        subject = -> { Expire.call(gift_purchase: @gift_purchase, at: @gift_purchase.expires_at) }

        assert_idempotent(subject, counter: -> { Orders::GiftPurchase.where(status: "expired").count })
      end

      private

      def committed_purchase_limit_allocation
        Ticketing::PurchaseLimitAllocation.create!(
          ticket_type: @gift_ticket_type,
          user: @gift_purchase.recipient_user,
          registration: @gift_registration,
          unit_number: 1,
          status: "committed",
          committed_at: Time.current,
          idempotency_key: "gift-expiry-allocation-#{SecureRandom.hex(5)}"
        )
      end
    end
  end
end
