# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class ExpireGiftClaimTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers
      include Ticketing::ConsentTestHelpers

      setup do
        setup_gift_purchase_context
      end

      test "expires a consent-pending gift registration and revokes its placeholder package" do
        create_consent_document(scope: "admission_slot", required: true)
        claim = Orders::GiftPurchases::Claim.call(
          gift_purchase_id: @gift_purchase.id,
          token: @gift_token,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
          ),
          idempotency_key: "expire-gift-claim-ticketing"
        )
        assert_predicate claim, :success?, claim.error&.message

        ticket = claim.value.ticket
        generation = ticket.current_credential_generation
        credential = generation.credentials.sole
        allocation = Ticketing::PurchaseLimitAllocation.create!(
          ticket_type: @gift_ticket_type,
          user: @gift_purchase.recipient_user,
          registration: @gift_registration,
          unit_number: 1,
          status: "committed",
          committed_at: Time.current,
          idempotency_key: "expire-gift-claim-limit-#{SecureRandom.hex(4)}"
        )
        suspension = Ticketing::Suspensions::Open.call(
          ticket:,
          actor: core_users(:super_admin),
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "expire-gift-claim-suspension-#{SecureRandom.hex(4)}"
        ).value

        result = ExpireGiftClaim.call(
          registration_id: @gift_registration.id,
          ticket_id: ticket.id,
          at: @gift_purchase.expires_at
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "expired", @gift_registration.reload.status
        assert_equal "void", ticket.reload.status
        assert_equal "revoked", generation.reload.status
        assert_equal "revoked", credential.reload.status
        assert ticket.revocation.reload.is_dead
        assert_not ticket.revocation.is_suspended
        assert_equal "released", allocation.reload.status
        assert_equal "expired", suspension.reload.status
        assert_equal "gift_claim_expired", suspension.resolution_reason
        assert_nil suspension.resolved_by_id

        replay = ExpireGiftClaim.call(
          registration_id: @gift_registration.id,
          ticket_id: ticket.id,
          at: @gift_purchase.expires_at
        )

        assert_predicate replay, :success?, replay.error&.message
        assert_equal 1, Core::AuditLog.where(
          auditable_type: "Ticketing::Registration",
          auditable_id: @gift_registration.id,
          action: "ticketing.registration.gift_claim_expired"
        ).count
      end
    end
  end
end
