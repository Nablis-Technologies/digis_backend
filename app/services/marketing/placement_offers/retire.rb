# frozen_string_literal: true

module Marketing
  module PlacementOffers
    # Retires a draft or active offer immediately for future sales without
    # changing placements that already captured its immutable terms.
    class Retire < Core::BaseService
      include Marketing::PlacementAdmin::CommandSupport

      RESOURCE_CLASS = PlacementOffer
      NOT_FOUND_ERROR_KEY = :placement_offer_not_found
      PERMISSION = "marketing_placement_offer.retire"
      AUDIT_ACTION = "marketing.placement_offer.retired"

      def initialize(offer_id:, actor:, idempotency_key:, reason:, at: Time.current)
        @offer_id = offer_id
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip
        @at = at.to_time.utc
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)
        return failure(error(:reason_required)) if @reason.blank?

        handle_errors do
          offer = PlacementOffer.find(@offer_id)
          key_digest = idempotency_digest
          digest = request_digest({
            operation: "retire", actor_id: @actor.id, offer_id: offer.id, reason: @reason
          })
          audit_key = "marketing-placement-offer-retire-#{key_digest}"
          replay = replay_result(audit_key:, request_digest: digest)
          next replay if replay

          ActiveRecord::Base.transaction do
            Core::Database::AdvisoryLock.acquire!("marketing", "placement_offer", offer.code)
            offer = PlacementOffer.lock.find(@offer_id)
            replay = replay_result(audit_key:, request_digest: digest)
            next replay if replay
            next failure(error(:offer_not_retirable, status: :conflict)) unless offer.draft? || offer.active?

            previous_status = offer.status
            offer.update!(status: "retired", retired_by: @actor, retired_at: @at)
            audit!(
              audit_key:, action: AUDIT_ACTION, record: offer, request_digest: digest, reason: @reason,
              previous_status:
            )
            success(offer)
          end
        end
      end
    end
  end
end
