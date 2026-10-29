# frozen_string_literal: true

require "test_helper"

module Marketing
  module PlacementOffers
    class ActivateTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @actor = core_users(:super_admin)
        @codes = []
      end

      teardown do
        offer_ids = PlacementOffer.where(code: @codes).pluck(:id)
        Core::AuditLog.where(auditable_type: "Marketing::PlacementOffer", auditable_id: offer_ids).delete_all
        PlacementOffer.where(id: offer_ids).delete_all
      end

      test "activates a draft for a future window with actor and reason evidence" do
        starts_at = 2.days.from_now
        offer = create_draft(starts_at:, ends_at: starts_at + 2.days)

        result = activate(offer)

        assert_predicate result, :success?, result.error&.message
        assert_equal "active", result.value.status
        assert_equal @actor.id, result.value.activated_by_id
        assert_not_nil result.value.activated_at
        audit = Core::AuditLog.find_by!(action: "marketing.placement_offer.activated", auditable_id: offer.id)
        assert_equal "Scheduled preview", audit.metadata.fetch("reason")
      end

      test "rejects overlapping active windows for versions of the same code" do
        starts_at = 2.days.from_now
        first = create_draft(starts_at:, ends_at: starts_at + 2.days)
        second = create_draft(
          code: first.code, starts_at: first.ends_at - 1.hour, ends_at: first.ends_at + 1.day
        )
        assert_predicate activate(first), :success?

        result = activate(second, idempotency_key: "overlap-#{SecureRandom.uuid}")

        assert_predicate result, :failure?
        assert_equal "offer_window_overlap", result.error.code
        assert_equal "draft", second.reload.status
      end

      test "allows adjacent half-open active windows for versions of the same code" do
        starts_at = 2.days.from_now
        first = create_draft(starts_at:, ends_at: starts_at + 2.days)
        second = create_draft(code: first.code, starts_at: first.ends_at, ends_at: first.ends_at + 1.day)

        assert_predicate activate(first), :success?
        adjacent = activate(second, idempotency_key: "adjacent-#{SecureRandom.uuid}")

        assert_predicate adjacent, :success?, adjacent.error&.message
      end

      test "same-key activation replay creates one audit and a different key cannot reactivate" do
        offer = create_draft(starts_at: 2.days.from_now, ends_at: 4.days.from_now)
        operation = -> { activate(offer, idempotency_key: "activate-replay-#{offer.id}") }
        assert_audit_idempotent(
          operation, action: "marketing.placement_offer.activated",
          auditable_type: "Marketing::PlacementOffer", auditable_id: offer.id
        )

        assert_predicate operation.call, :success?
        conflicting = activate(offer, idempotency_key: "activate-again-#{offer.id}")

        assert_predicate conflicting, :failure?
        assert_equal "offer_not_draft", conflicting.error.code
      end

      test "serializes concurrent activations of overlapping versions" do
        assert defined?(Activate), "Marketing::PlacementOffers::Activate should be implemented"

        starts_at = 2.days.from_now
        first = create_draft(starts_at:, ends_at: starts_at + 2.days)
        second = create_draft(code: first.code, starts_at:, ends_at: starts_at + 2.days)
        actor_id = @actor.id
        offer_ids = [ first.id, second.id ]
        race = Prosopite.pause do
          run_database_race do |index|
            offer_id = offer_ids.fetch(index)
            Activate.call(
              offer_id:, actor: Core::User.find(actor_id),
              idempotency_key: "concurrent-activate-#{offer_id}", reason: "Concurrent activation"
            )
          end
        end
        results = race.results

        assert_empty race.errors, race.errors.inspect
        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count(&:failure?)
        assert_equal "offer_window_overlap", results.find(&:failure?).error.code
        assert_equal %w[active draft], PlacementOffer.where(id: offer_ids).order(:status).pluck(:status)
      end

      private

      def create_draft(code: "activation_#{SecureRandom.hex(5)}", starts_at: 2.days.from_now,
        ends_at: starts_at + 2.days)
        @codes << code
        result = Create.call(
          actor: @actor,
          attributes: {
            code:, surface: "public_discovery", daily_rate_minor: 50_000, currency: "ETB",
            minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
            terms_version: "activation-test", starts_at:, ends_at:
          },
          idempotency_key: "create-#{SecureRandom.uuid}", reason: "Activation test"
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def activate(offer, idempotency_key: "activate-#{offer.id}", reason: "Scheduled preview")
        assert defined?(Activate), "Marketing::PlacementOffers::Activate should be implemented"

        Activate.call(offer_id: offer.id, actor: @actor, idempotency_key:, reason:)
      end
    end
  end
end
