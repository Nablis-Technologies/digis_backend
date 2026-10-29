# frozen_string_literal: true

module Messaging
  module Campaigns
    # Claims and delivers one campaign row without holding a DB lock over I/O.
    class Deliver < Core::BaseService
      DeliveryOutcome = Data.define(:delivery, :allocation, :outcome, :reason)

      class ClaimLost < Core::BusinessError
        def initialize
          super(I18n.t("messaging.errors.delivery_claim_lost"), code: "delivery_claim_lost", status: :conflict)
        end
      end

      CLAIM_TIMEOUT = 5.minutes
      RETRY_DELAY = 30.seconds
      RETRY_BACKOFF_CAP = 1.hour
      MAX_ATTEMPTS = 5

      def initialize(delivery_id: nil, delivery: nil, settle: true)
        @delivery = delivery
        @delivery_id = delivery_id || delivery&.id
        @settle = settle
      end

      def call
        delivery = claim_delivery
        return success(nil) unless delivery
        return success(finalize_suppressed(delivery)) if delivery.campaign_recipient.eligibility_status == "suppressed"

        adapter = provider_registry.fetch(channel: delivery.channel)
        return success(finalize_unavailable(delivery)) unless adapter

        result = adapter.deliver_campaign(
          campaign: delivery.campaign,
          delivery:,
          content: content_for(delivery),
          idempotency_key: delivery.idempotency_key_digest
        )
        return failure(error(:invalid_delivery_result)) unless result.is_a?(Providers::DeliveryResult)

        success(finalize(delivery, result))
      rescue Core::Error => exception
        failure(exception)
      rescue StandardError => exception
        if delivery
          outcome = release_for_retry(delivery, exception)
          return success(outcome) if outcome
        end
        failure(error(:delivery_failed, message: exception.message))
      end

      private

      def claim_delivery
        return claim_loaded_delivery if @delivery

        CampaignDelivery.transaction do
          delivery = CampaignDelivery.includes(
            { campaign: %i[organization event] }, :campaign_recipient, :credit_allocation
          ).lock.find(@delivery_id)
          return if delivery.terminal?
          return if delivery.claimed_at.present? && delivery.claimed_at > CLAIM_TIMEOUT.ago

          delivery.update!(status: "processing", claimed_at: Time.current, attempts: delivery.attempts + 1)
          delivery
        end
      end

      def claim_loaded_delivery
        return if @delivery.terminal?
        return if @delivery.claimed_at.present? && @delivery.claimed_at > CLAIM_TIMEOUT.ago

        claimed_at = Time.current
        updated = CampaignDelivery.where(id: @delivery.id, status: "pending")
          .update_all(status: "processing", claimed_at:,
            attempts: @delivery.attempts + 1, updated_at: Time.current)
        raise ClaimLost unless updated == 1

        @delivery.status = "processing"
        @delivery.claimed_at = claimed_at
        @delivery.attempts += 1
        @delivery
      end

      def provider_registry
        Rails.application.config.x.messaging_provider_registry
      end

      def content_for(delivery)
        campaign = delivery.campaign
        values = Templates::Context.values(campaign:, recipient: delivery.campaign_recipient)
        {
          subject: Templates::Interpolator.call(campaign.message_subject, values:, escape_values: false),
          body: Templates::Interpolator.call(
            campaign.message_body, values:, escape_values: campaign.channel == "email"
          )
        }
      end

      def finalize_suppressed(delivery)
        finalize_outcome(delivery, :suppressed, "suppressed", status: "suppressed", claimed_at: nil,
          next_attempt_at: nil)
      end

      def finalize_unavailable(delivery)
        finalize_outcome(delivery, :failed, "provider_unavailable", status: "unavailable", claimed_at: nil,
          failed_at: Time.current, failure_code: "provider_unavailable")
      end

      def finalize(delivery, result)
        if result.success?
          finalize_outcome(delivery, :delivered, "delivered", status: result.status, provider: result.provider,
            provider_message_id: result.provider_message_id, sent_at: Time.current,
            delivered_at: result.status == "delivered" ? Time.current : nil, claimed_at: nil)
        elsif result.retryable
          finalize_retryable(delivery, result)
        else
          finalize_outcome(delivery, :failed, result.failure_code, status: "failed", provider: result.provider,
            failed_at: Time.current, claimed_at: nil, failure_code: result.failure_code,
            failure_detail: result.failure_detail.to_s.first(500))
        end
      end

      def finalize_retryable(delivery, result)
        return finalize_outcome(delivery, :failed, "max_attempts_exceeded", status: "failed",
          provider: result.provider, failed_at: Time.current, claimed_at: nil,
          failure_code: "max_attempts_exceeded", failure_detail: result.failure_detail.to_s.first(500)) if
          delivery.attempts >= MAX_ATTEMPTS

        finalize_outcome(delivery, :retryable, result.failure_code, status: "pending", provider: result.provider,
          next_attempt_at: retry_at(delivery), claimed_at: nil, failure_code: result.failure_code,
          failure_detail: result.failure_detail.to_s.first(500))
      end

      def finalize_outcome(delivery, outcome, reason, **attributes)
        return persist_and_settle(delivery, outcome, reason, attributes) if @settle

        persisted = update_claimed(delivery, **attributes)

        DeliveryOutcome.new(delivery: persisted, allocation: delivery.credit_allocation, outcome:, reason:)
      end

      def persist_and_settle(delivery, outcome, reason, attributes)
        CampaignDelivery.transaction do
          persisted = update_claimed(delivery, **attributes)
          settle(delivery, outcome, reason)
          persisted
        end
      end

      def settle(delivery, outcome, reason)
        result = CreditHolds::Settle.call(
          allocation: allocation_for(delivery), outcome:, reason:,
          idempotency_key: "campaign-delivery-settle-#{delivery.id}-#{outcome}"
        )
        raise result.error if result.failure?
      end

      def release_for_retry(delivery, exception)
        if delivery.attempts >= MAX_ATTEMPTS
          attributes = {
            status: "failed", failed_at: Time.current, claimed_at: nil,
            failure_code: "max_attempts_exceeded", failure_detail: exception.message.to_s.first(500)
          }
          return persist_and_settle(delivery, :failed, "max_attempts_exceeded", attributes) if @settle

          persisted = update_claimed(delivery, **attributes)

          DeliveryOutcome.new(
            delivery: persisted, allocation: persisted.credit_allocation,
            outcome: :failed, reason: "max_attempts_exceeded"
          )
        else
          persisted = update_claimed(delivery, status: "pending", next_attempt_at: retry_at(delivery),
            claimed_at: nil, failure_code: "provider_error", failure_detail: exception.message.to_s.first(500))
          return persisted if @settle

          DeliveryOutcome.new(
            delivery: persisted, allocation: persisted.credit_allocation,
            outcome: :retryable, reason: "provider_error"
          )
        end
      end

      def retry_at(delivery)
        delay = [ RETRY_DELAY * (2**(delivery.attempts - 1)), RETRY_BACKOFF_CAP ].min
        delay.from_now
      end

      def allocation_for(delivery)
        delivery.credit_allocation
      end

      def update_claimed(delivery, **attributes)
        updated = CampaignDelivery.where(id: delivery.id, status: "processing", claimed_at: delivery.claimed_at)
          .update_all(attributes.merge(updated_at: Time.current))
        if updated == 1
          if @delivery
            delivery.assign_attributes(attributes.merge(updated_at: Time.current))
            return delivery
          end

          return delivery.reload
        end

        raise ClaimLost
      end

      def error(key, message: nil, status: :failed_dependency)
        Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
