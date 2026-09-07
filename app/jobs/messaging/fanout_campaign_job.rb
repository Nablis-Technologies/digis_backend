# frozen_string_literal: true

module Messaging
  # Claims 100 recipients, commits allocations, then delivers outside the lock.
  class FanoutCampaignJob < ApplicationJob
    BATCH_SIZE = 100

    queue_as :notifications

    def perform(campaign_id, cursor = {})
      campaign = Campaign.find(campaign_id)
      return if campaign.status.in?(%w[paused canceled completed failed])

      recipients, deliveries, mode = claim_recipients(campaign, cursor.to_h["after_recipient_id"])
      allocations = CampaignCreditAllocation.where(delivery_id: deliveries.map(&:id)).index_by(&:delivery_id)
      deliveries.each { |delivery| delivery.association(:credit_allocation).target = allocations.fetch(delivery.id) }
      outcomes = deliveries.filter_map do |delivery|
        result = Campaigns::Deliver.call(delivery:, settle: false)
        result.success? ? result.value : nil
      end
      settlement = Campaigns::CreditHolds::SettleBatch.call(outcomes:)
      raise settlement.error if settlement.failure?
      completed = complete_if_finished(campaign)
      schedule_next(campaign, recipients, cursor, mode:, completed:)
    end

    private

    def claim_recipients(campaign, after_recipient_id)
      Campaign.transaction do
        current = Campaign.includes(:organization, :event).lock.find(campaign.id)
        return [ [], [], :none ] unless current.status == "sending"

        hold = CreditReservation.find_by!(source_type: "Messaging::Campaign", source_id: current.id)
        due_deliveries = CampaignDelivery.includes(:campaign, :campaign_recipient, :credit_allocation)
          .where(campaign_id: current.id, status: "pending")
          .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
          .order(:id).limit(BATCH_SIZE).lock("FOR UPDATE SKIP LOCKED").to_a
        return [ due_deliveries.map(&:campaign_recipient), due_deliveries, :retry ] if due_deliveries.any?

        recipients = CampaignRecipient.where(campaign_id: current.id, eligibility_status: %w[eligible suppressed])
          .where.not(id: CampaignDelivery.where(campaign_id: current.id).select(:campaign_recipient_id))
        recipients = recipients.where("messaging_campaign_recipients.id > ?", after_recipient_id) if after_recipient_id.present?
        recipients = recipients.order(:id).limit(BATCH_SIZE).lock("FOR UPDATE SKIP LOCKED").to_a

        deliveries = []
        recipients.each do |recipient|
          delivery = CampaignDelivery.create_or_find_by!(campaign: current, campaign_recipient: recipient) do |row|
            row.assign_attributes(
              channel: current.channel,
              status: "pending",
              idempotency_key_digest: Core::KeyedDigest.digest(
                namespace: "messaging-campaign-delivery", value: "#{current.id}:#{recipient.id}"
              )
            )
          end
          deliveries << delivery
        end
        allocation = Campaigns::CreditHolds::AllocateBatch.call(reservation: hold, deliveries:)
        raise allocation.error if allocation.failure?
        [ recipients, deliveries, :fresh ]
      end
    end

    def schedule_next(campaign, recipients, cursor, mode:, completed:)
      return if completed || campaign.reload.status != "sending"

      if mode == :fresh && recipients.length == BATCH_SIZE
        enqueue_next(campaign, recipients.last.id)
      elsif work_remaining?(campaign)
        next_cursor = mode == :fresh ? nil : cursor.to_h["after_recipient_id"]
        retry_at = CampaignDelivery.where(campaign_id: campaign.id, status: "pending")
          .where.not(next_attempt_at: nil).minimum(:next_attempt_at)
        if retry_at.present? && retry_at > Time.current
          enqueue_next(campaign, next_cursor, wait_until: retry_at)
        else
          enqueue_next(campaign, next_cursor)
        end
      end
    end

    def work_remaining?(campaign)
      CampaignDelivery.where(campaign_id: campaign.id, status: "pending").exists? ||
        CampaignRecipient.where(campaign_id: campaign.id, eligibility_status: %w[eligible suppressed])
          .where.not(id: CampaignDelivery.where(campaign_id: campaign.id).select(:campaign_recipient_id)).exists?
    end

    def complete_if_finished(campaign)
      Campaign.transaction do
        current = Campaign.lock.find(campaign.id)
        return false unless current.status == "sending"
        return false if CampaignDelivery.where(campaign_id: current.id, status: %w[pending processing]).exists?
        return false if CampaignRecipient.where(campaign_id: current.id, eligibility_status: %w[eligible suppressed])
          .where.not(id: CampaignDelivery.where(campaign_id: current.id).select(:campaign_recipient_id)).exists?

        hold = CreditReservation.find_by(source_type: "Messaging::Campaign", source_id: current.id)
        if hold
          result = Campaigns::CreditHolds::Finalize.call(
            reservation: hold, resolution_code: "campaign_completed"
          )
          raise result.error if result.failure?
        end
        current.update!(status: "completed", completed_at: Time.current)
        true
      end
    end

    def enqueue_next(campaign, after_recipient_id, wait_until: nil)
      job = FanoutCampaignJob.set(wait_until: wait_until) if wait_until
      (job || FanoutCampaignJob).perform_later(campaign.id, { "after_recipient_id" => after_recipient_id }.compact)
    end
  end
end
