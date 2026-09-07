# frozen_string_literal: true

module Messaging
  module Campaigns
    # Withdraws a draft/scheduled campaign and releases its full hold.
    class Cancel < Core::BaseService
      include LifecycleCommandSupport

      def initialize(campaign:, actor:, reason:, idempotency_key:)
        @campaign = campaign
        @actor = actor
        @reason = reason.to_s.strip
        @raw_idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        return failure(error(:unauthorized, status: :forbidden)) unless Events::AuthorizationResolver.organization_admin?(@actor, @campaign.organization)
        return failure(error(:reason_required)) if @reason.blank?

        request_digest = lifecycle_request_digest(action: "canceled", key:, reason: @reason)
        audit_key = lifecycle_audit_key(action: "canceled", key:)
        ActiveRecord::Base.transaction do
          campaign = Campaign.lock.find(@campaign.id)
          replay = lifecycle_replay(audit_key:, request_digest:, campaign:)
          return replay if replay
          return success(campaign) if campaign.status == "canceled"
          return failure(error(:campaign_invalid_state, status: :conflict)) unless campaign.status.in?(%w[draft scheduled])

          hold = CreditReservation.lock.find_by(source_type: "Messaging::Campaign", source_id: campaign.id)
          if hold
            result = CreditHolds::Finalize.call(
              reservation: hold, resolution_code: "campaign_canceled"
            )
            return failure(result.error) if result.failure?
          end
          previous_status = campaign.status
          campaign.update!(status: "canceled", canceled_at: Time.current)
          record_lifecycle_audit!(action: "messaging.campaign.canceled", audit_key:, request_digest:, key:, campaign:,
            from: previous_status, to: "canceled", reason: @reason)
          success(campaign)
        end
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:campaign_invalid_state, message: exception.message))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def error(key, message: nil, status: :unprocessable_entity)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
