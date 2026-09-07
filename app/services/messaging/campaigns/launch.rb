# frozen_string_literal: true

module Messaging
  module Campaigns
    # Claims the quoted aggregate and hands delivery to the outbox.
    class Launch < Core::BaseService
      def initialize(campaign:, actor:, idempotency_key:, quote_digest: nil,
        quoted_rate_version_id: nil, quoted_quantity: nil)
        @campaign = campaign
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @quote_digest = quote_digest
        @quoted_rate_version_id = quoted_rate_version_id
        @quoted_quantity = quoted_quantity
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?

        ActiveRecord::Base.transaction do
          campaign = Campaign.lock.find(@campaign.id)
          existing_hold = CreditReservation.find_by(source_type: "Messaging::Campaign", source_id: campaign.id)
          if existing_hold && campaign.metadata.to_h["launch_idempotency_key_digest"] == key.digest
            return success(campaign) if quote_identity_matches?(campaign)

            return failure(error(:campaign_quote_stale, status: :conflict))
          end
          if existing_hold && campaign.status.in?(%w[sending scheduled])
            return failure(error(:campaign_quote_stale, status: :conflict)) unless quote_valid?(campaign)

            return failure(error(:idempotency_conflict, status: :conflict))
          end
          return failure(error(:campaign_invalid_state, status: :conflict)) unless campaign.status == "draft"
          return failure(error(:campaign_audience_snapshot_invalid, status: :conflict)) unless campaign.audience_snapshot&.status == "ready"
          return failure(error(:campaign_quote_stale, status: :conflict)) unless quote_valid?(campaign)
          return failure(error(:campaign_attestation_required, status: :unprocessable_entity)) unless attested?(campaign)
          quota = Quota.call(
            organization: campaign.organization, channel: campaign.channel, quantity: campaign.quoted_quantity,
            timezone: campaign.timezone
          )
          return failure(quota.error) if quota.failure?

          account = CreditAccount.create_or_find_by!(organization: campaign.organization, channel: campaign.channel)
          hold_result = CreditHolds::Reserve.call(
            account:, organization: campaign.organization, rate_version: campaign.quoted_rate_version,
            source_type: "Messaging::Campaign", source_id: campaign.id, quantity: campaign.quoted_quantity,
            idempotency_key: "campaign-launch-#{campaign.id}-#{key}"
          )
          return failure(hold_result.error) if hold_result.failure?

          status = campaign.send_at.present? && campaign.send_at > Time.current ? "scheduled" : "sending"
          campaign.update!(
            status:, launched_at: Time.current,
            metadata: campaign.metadata.merge("launch_idempotency_key_digest" => key.digest)
          )
          audit = Core::Audit::Record.call(
            audit_key: "messaging-campaign-launch-#{campaign.id}-#{key.digest}",
            action: "messaging.campaign.launched",
            auditable_type: campaign.class.name, auditable_id: campaign.id,
            actor_type: @actor.class.name, actor_id: @actor.id,
            audited_changes: { "status" => [ "draft", status ] },
            metadata: { "request_digest" => key.digest, "campaign_id" => campaign.id }
          )
          return failure(audit.error) if audit.failure?

          publication = Core::Outbox::Publish.call(
            topic: "messaging", event_type: "messaging.campaign.launched", aggregate: campaign,
            payload: {
              "campaign_id" => campaign.id,
              "credit_hold_id" => hold_result.value.id,
              "dispatch_at" => campaign.send_at&.iso8601,
              "launch_version" => campaign.launch_version
            },
            idempotency_key: "messaging-campaign-launched-#{campaign.id}-v#{campaign.launch_version}"
          )
          return failure(publication.error) if publication.failure?

          success(campaign)
        end
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_invalid_state, message: exception.message))
      end

      private

      def authorized?
        Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
      end

      def attested?(campaign)
        CampaignAttestation.exists?(campaign_id: campaign.id, audience_snapshot_id: campaign.audience_snapshot&.id)
      end

      def quote_valid?(campaign)
        return false if campaign.quote_expires_at.blank? || campaign.quote_expires_at <= Time.current
        quote_identity_matches?(campaign)
      end

      def quote_identity_matches?(campaign)
        return false unless campaign.quoted_rate_version_id && campaign.quoted_quantity &&
          campaign.quoted_unit_price_minor && campaign.quote_digest
        return false unless @quote_digest == campaign.quote_digest
        return false unless @quoted_rate_version_id == campaign.quoted_rate_version_id
        return false unless @quoted_quantity.to_i == campaign.quoted_quantity

        true
      end

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
