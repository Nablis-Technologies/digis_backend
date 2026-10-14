# frozen_string_literal: true

module Marketing
  module PlacementOffers
    # Activates one immutable offer version after serializing checks for its
    # code. The half-open effective windows may touch, but may not overlap.
    class Activate < Core::BaseService
      include Marketing::PlacementAdmin::CommandSupport

      RESOURCE_CLASS = PlacementOffer
      NOT_FOUND_ERROR_KEY = :placement_offer_not_found
      PERMISSION = "marketing_placement_offer.activate"
      AUDIT_ACTION = "marketing.placement_offer.activated"

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
            operation: "activate", actor_id: @actor.id, offer_id: offer.id, reason: @reason
          })
          audit_key = "marketing-placement-offer-activate-#{key_digest}"
          replay = replay_result(audit_key:, request_digest: digest)
          next replay if replay

          ActiveRecord::Base.transaction do
            Core::Database::AdvisoryLock.acquire!("marketing", "placement_offer", offer.code)
            offer = PlacementOffer.lock.find(@offer_id)
            replay = replay_result(audit_key:, request_digest: digest)
            next replay if replay
            next failure(error(:offer_not_draft, status: :conflict)) unless offer.draft?
            next failure(error(:offer_window_overlap, status: :conflict)) if overlapping_offer?(offer)

            offer.update!(status: "active", activated_by: @actor, activated_at: @at)
            audit!(
              audit_key:, action: AUDIT_ACTION, record: offer, request_digest: digest, reason: @reason,
              previous_status: "draft"
            )
            success(offer)
          end
        end
      end

      private

      def overlapping_offer?(offer)
        PlacementOffer.where(code: offer.code, status: "active")
          .where("starts_at < ? AND ends_at > ?", offer.ends_at, offer.starts_at)
          .where.not(id: offer.id)
          .exists?
      end
    end
  end
end
