# frozen_string_literal: true

module Messaging
  module Campaigns
    # Records the organizer's permission assertion without copying contacts.
    class Attest < Core::BaseService
      def initialize(campaign:, audience_snapshot:, actor:, channel:, confirmation:, idempotency_key:,
        historical_basis: nil, statement_version: 1)
        @campaign = campaign
        @snapshot = audience_snapshot
        @actor = actor
        @channel = channel.to_s.strip.downcase
        @historical_basis = historical_basis.to_s.strip.presence
        @confirmation = confirmation == true
        @statement_version = statement_version
        @key = Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        return failure(error(:campaign_attestation_confirmation_required)) unless @confirmation
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?
        return failure(error(:campaign_audience_invalid)) unless valid_target?

        request_digest = request_digest_for
        existing = CampaignAttestation.find_by(
          campaign_id: @campaign.id,
          idempotency_key_digest: @key.digest
        )
        return replay(existing, request_digest) if existing

        attestation = CampaignAttestation.create!(
          campaign: @campaign,
          audience_snapshot: @snapshot,
          actor: @actor,
          channel: @channel,
          historical_basis: @historical_basis,
          statement_version: @statement_version,
          idempotency_key_digest: @key.digest,
          request_digest:,
          attested_at: Time.current,
          metadata: { "source_spec_digest" => source_spec_digest }
        )
        success(attestation)
      rescue ActiveRecord::RecordNotUnique
        replay(
          CampaignAttestation.find_by!(campaign_id: @campaign.id, idempotency_key_digest: @key.digest),
          request_digest_for
        )
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_audience_invalid, message: exception.message))
      end

      private

      def authorized?
        Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
      end

      def valid_target?
        Campaign::CHANNELS.include?(@channel) && @snapshot&.campaign_id == @campaign.id &&
          @snapshot&.status == "ready" && @statement_version.to_i.positive?
      end

      def request_digest_for
        Core::KeyedDigest.digest(
          namespace: "messaging-campaign-attestation",
          value: ActiveSupport::JSON.encode(
            campaign_id: @campaign.id, snapshot_id: @snapshot.id, actor_id: @actor.id,
            channel: @channel, historical_basis: @historical_basis, statement_version: @statement_version
          )
        )
      end

      def source_spec_digest
        Core::KeyedDigest.digest(
          namespace: "messaging-campaign-attestation-source",
          value: ActiveSupport::JSON.encode(@snapshot.source_spec)
        )
      end

      def replay(existing, request_digest)
        return failure(error(:idempotency_conflict, status: :conflict)) unless existing.request_digest == request_digest

        success(existing)
      end

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
