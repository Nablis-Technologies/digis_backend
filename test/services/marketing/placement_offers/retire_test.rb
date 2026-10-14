# frozen_string_literal: true

require "test_helper"

module Marketing
  module PlacementOffers
    class RetireTest < ActiveSupport::TestCase
      setup do
        @actor = core_users(:super_admin)
      end

      test "retires draft and active offers with actor and timestamp evidence" do
        draft = create_draft
        active = activate(create_draft)

        retired_draft = retire(draft, idempotency_key: "retire-draft-#{draft.id}")
        retired_active = retire(active, idempotency_key: "retire-active-#{active.id}")

        [ retired_draft, retired_active ].each do |result|
          assert_predicate result, :success?, result.error&.message
          assert_equal "retired", result.value.status
          assert_equal @actor.id, result.value.retired_by_id
          assert_not_nil result.value.retired_at
          refute result.value.purchasable_at?
        end
        assert_equal @actor.id, retired_active.value.activated_by_id
        assert_not_nil retired_active.value.activated_at
      end

      test "same-key retirement replay is idempotent and a new key cannot retire twice" do
        offer = activate(create_draft)
        operation = -> { retire(offer, idempotency_key: "retire-replay-#{offer.id}") }
        assert_audit_idempotent(
          operation, action: "marketing.placement_offer.retired",
          auditable_type: "Marketing::PlacementOffer", auditable_id: offer.id
        )

        result = operation.call
        repeated = retire(offer, idempotency_key: "retire-again-#{offer.id}")

        assert_predicate result, :success?, result.error&.message
        assert_predicate repeated, :failure?
        assert_equal "offer_not_retirable", repeated.error.code
      end

      test "retirement leaves an already-paid placement and its price snapshot unchanged" do
        offer = activate(create_draft)
        event = events_events(:ready_listing)
        starts_at = 1.day.from_now.change(usec: 0)
        placement = FeaturedPlacement.create!(
          event:, organization_id: event.organization_id, placement_offer: offer,
          status: "scheduled", surface: offer.surface, starts_at:, ends_at: starts_at + 24.hours,
          duration_seconds: 24.hours.to_i, offer_code: offer.code, offer_version: offer.version,
          daily_rate_minor: offer.daily_rate_minor, amount_minor: offer.daily_rate_minor, currency: offer.currency,
          terms_version: offer.terms_version, price_digest: SecureRandom.hex(32),
          idempotency_key_digest: SecureRandom.hex(32), request_digest: SecureRandom.hex(32)
        )
        original_snapshot = placement.attributes.slice(
          "status", "offer_code", "offer_version", "daily_rate_minor", "amount_minor", "currency",
          "terms_version", "starts_at", "ends_at"
        )

        result = retire(offer, idempotency_key: "retire-with-placement-#{offer.id}")

        assert_predicate result, :success?, result.error&.message
        assert_equal original_snapshot, placement.reload.attributes.slice(*original_snapshot.keys)
      end

      private

      def create_draft(code: "retire_#{SecureRandom.hex(5)}")
        result = Create.call(
          actor: @actor,
          attributes: {
            code:, surface: "public_discovery", daily_rate_minor: 50_000, currency: "ETB",
            minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
            terms_version: "retire-test", starts_at: 1.day.ago, ends_at: 30.days.from_now
          },
          idempotency_key: "create-retire-#{SecureRandom.uuid}", reason: "Retirement test"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def activate(offer)
        result = Activate.call(
          offer_id: offer.id, actor: @actor,
          idempotency_key: "activate-retire-#{offer.id}", reason: "Prepare retirement test"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def retire(offer, idempotency_key:)
        assert defined?(Retire), "Marketing::PlacementOffers::Retire should be implemented"

        Retire.call(offer_id: offer.id, actor: @actor, idempotency_key:, reason: "Retired preview offer")
      end
    end
  end
end
