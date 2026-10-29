# frozen_string_literal: true

require "test_helper"

module Marketing
  module PlacementOffers
    class CreateTest < ActiveSupport::TestCase
      setup do
        @actor = core_users(:super_admin)
        @attributes = {
          code: "public_discovery_#{SecureRandom.hex(3)}", version: 900,
          surface: "public_discovery", daily_rate_minor: 50_000, currency: "ETB",
          minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 7.days.to_i,
          terms_version: "preview-v1", starts_at: 1.day.ago, ends_at: 30.days.from_now
        }
      end

      test "creates normalized immutable offer drafts and assigns versions on the server" do
        code = " normalized_code_#{SecureRandom.hex(3)} "
        first = create_offer(attributes: @attributes.merge(code:, currency: "etb", terms_version: " v2 "))
        second = create_offer(attributes: @attributes.merge(code:, currency: "etb", terms_version: " v2 "),
          idempotency_key: "offer-version-second")

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal "normalized_code_#{code.strip.split("_").last}", first.value.code
        assert_equal "ETB", first.value.currency
        assert_equal "v2", first.value.terms_version
        assert_equal [ 1, 2 ], [ first.value.version, second.value.version ]
        assert_equal "draft", first.value.status
        assert_equal @actor.id, first.value.created_by_id
        assert_nil first.value.activated_by_id
      end

      test "replays the original draft without allocating another version or audit" do
        first = nil
        operation = lambda do
          result = create_offer(idempotency_key: "offer-create-replay")
          first ||= result
          result
        end
        assert_idempotent(operation, counter: -> { PlacementOffer.count })

        replay = operation.call

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
        audit = Core::AuditLog.find_by!(action: "marketing.placement_offer.created", auditable_id: first.value.id)
        assert_equal @actor.id, audit.actor_id
        assert_equal "Created preview pricing", audit.metadata.fetch("reason")
      end

      test "rejects changed content under a previously used idempotency key" do
        first = create_offer(idempotency_key: "offer-create-conflict")
        second = create_offer(
          attributes: @attributes.merge(daily_rate_minor: 60_000),
          idempotency_key: "offer-create-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, PlacementOffer.where(code: @attributes[:code]).count
      end

      test "requires a reason and an authorized platform administrator" do
        missing_reason = create_offer(reason: " ")
        forbidden = create_offer(actor: core_users(:attendee), idempotency_key: "offer-create-forbidden")

        assert_predicate missing_reason, :failure?
        assert_equal "reason_required", missing_reason.error.code
        assert_predicate forbidden, :failure?
        assert_equal :forbidden, forbidden.error.status
      end

      test "records one audit for the exact idempotent create" do
        result = create_offer(idempotency_key: "offer-create-audit")

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, Core::AuditLog.where(
          action: "marketing.placement_offer.created", auditable_id: result.value.id
        ).count
      end

      test "database uniqueness remains the version allocation race backstop" do
        result = create_offer(idempotency_key: "offer-create-unique-index")
        attributes = result.value.attributes.merge(
          "id" => SecureRandom.uuid,
          "idempotency_key_digest" => SecureRandom.hex(32),
          "request_digest" => SecureRandom.hex(32)
        )

        assert_raises(ActiveRecord::RecordNotUnique) do
          PlacementOffer.insert_all!([ attributes ])
        end
      end

      private

      def create_offer(actor: @actor, attributes: @attributes, idempotency_key: "offer-create-default",
        reason: "Created preview pricing")
        assert defined?(Create), "Marketing::PlacementOffers::Create should be implemented"

        Create.call(actor:, attributes:, idempotency_key:, reason:)
      end
    end
  end
end
