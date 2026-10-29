# frozen_string_literal: true

module Marketing
  module PlacementOffers
    # Creates immutable offer drafts; only an authorized admin lifecycle
    # command may make a draft purchasable.
    class Create < Core::BaseService
      include Marketing::PlacementAdmin::CommandSupport

      RESOURCE_CLASS = PlacementOffer
      NOT_FOUND_ERROR_KEY = :placement_offer_not_found
      PERMISSION = "marketing_placement_offer.create"
      AUDIT_ACTION = "marketing.placement_offer.created"

      def initialize(actor:, attributes:, idempotency_key:, reason:)
        @actor = actor
        @attributes = attributes
        @raw_idempotency_key = idempotency_key
        @reason = reason.to_s.strip
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)
        return failure(error(:reason_required)) if @reason.blank?

        handle_errors do
          key_digest = idempotency_digest
          attributes = canonical_attributes
          digest = request_digest({ actor_id: @actor.id, attributes:, reason: @reason })
          audit_key = "marketing-placement-offer-create-#{key_digest}"
          replay = replay_result(audit_key:, request_digest: digest)
          next replay if replay

          ActiveRecord::Base.transaction do
            Core::Database::AdvisoryLock.acquire!("marketing", "placement_offer", attributes.fetch(:code))
            replay = replay_result(audit_key:, request_digest: digest)
            next replay if replay

            offer = PlacementOffer.create!(
              attributes.merge(
                version: next_version(attributes.fetch(:code)), status: "draft", created_by: @actor,
                idempotency_key_digest: key_digest, request_digest: digest
              )
            )
            audit!(audit_key:, action: AUDIT_ACTION, record: offer, request_digest: digest, reason: @reason)
            success(offer)
          end
        end
      end

      private

      def canonical_attributes
        source = @attributes.respond_to?(:to_unsafe_h) ? @attributes.to_unsafe_h : @attributes.to_h
        fields = source.deep_symbolize_keys.slice(
          :code, :surface, :daily_rate_minor, :currency, :minimum_duration_seconds,
          :maximum_duration_seconds, :terms_version, :starts_at, :ends_at
        )
        fields[:code] = fields[:code].to_s.strip.downcase
        fields[:surface] = fields[:surface].to_s.strip.downcase
        fields[:currency] = fields[:currency].to_s.strip.upcase
        fields[:terms_version] = fields[:terms_version].to_s.strip
        fields
      end

      def next_version(code)
        PlacementOffer.where(code:).maximum(:version).to_i + 1
      end
    end
  end
end
