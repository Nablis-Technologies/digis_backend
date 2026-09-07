# frozen_string_literal: true

module Messaging
  # Reclaims stale delivery leases and resumes preparing audience snapshots.
  class ReconcileCampaignsJob < ApplicationJob
    BATCH_SIZE = 100
    CLAIM_TIMEOUT = 5.minutes
    TERMINAL_CAMPAIGN_STATUSES = %w[canceled completed failed].freeze

    queue_as :notifications

    def perform
      reclaim_stale_deliveries
      requeue_terminal_deliveries
      refund_unattempted_terminal_deliveries
      requeue_sending_campaigns
      finalize_terminal_holds
      resume_preparing_snapshots
    end

    private

    def reclaim_stale_deliveries
      ids = CampaignDelivery.where(status: "processing").where("claimed_at <= ?", CLAIM_TIMEOUT.ago)
        .order(:claimed_at, :id).limit(BATCH_SIZE).pluck(:id)
      return if ids.empty?

      terminal_ids = CampaignDelivery.transaction do
        ids.filter_map do |delivery_id|
          delivery = CampaignDelivery.find_by(id: delivery_id)
          next unless delivery

          campaign = Campaign.lock.find(delivery.campaign_id)
          delivery.lock!
          next unless stale_processing?(delivery)

          if terminal_campaign?(campaign)
            delivery.id
          else
            delivery.update_columns(
              status: "pending", claimed_at: nil, next_attempt_at: Time.current,
              updated_at: Time.current
            )
            nil
          end
        end
      end
      terminal_ids.each { |delivery_id| RecoverCampaignDeliveryJob.perform_later(delivery_id) }
    end

    def requeue_terminal_deliveries
      CampaignDelivery.joins(:campaign, :credit_allocation)
        .where(messaging_campaigns: { status: TERMINAL_CAMPAIGN_STATUSES }, status: "pending", attempts: 1..)
        .where(messaging_campaign_credit_allocations: { status: "allocated" })
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
        .order(:id).limit(BATCH_SIZE).pluck(:id)
        .each { |delivery_id| RecoverCampaignDeliveryJob.perform_later(delivery_id) }
    end

    def refund_unattempted_terminal_deliveries
      ids = CampaignDelivery.joins(:campaign, :credit_allocation)
        .where(messaging_campaigns: { status: TERMINAL_CAMPAIGN_STATUSES }, status: "pending", attempts: 0)
        .where(messaging_campaign_credit_allocations: { status: "allocated" })
        .order(:id).limit(BATCH_SIZE).pluck(:id)
      ids.each { |delivery_id| refund_unattempted_delivery(delivery_id) }
    end

    def refund_unattempted_delivery(delivery_id)
      CampaignDelivery.transaction do
        delivery = CampaignDelivery.find_by(id: delivery_id)
        next unless delivery

        campaign = Campaign.lock.find(delivery.campaign_id)
        delivery.lock!
        next unless terminal_campaign?(campaign) && delivery.status == "pending" && delivery.attempts.zero?

        allocation = CampaignCreditAllocation.lock.find_by(delivery_id: delivery.id)
        next unless allocation&.status == "allocated"

        result = Campaigns::CreditHolds::Settle.call(
          allocation:, outcome: :failed, reason: "campaign_aborted",
          idempotency_key: "campaign-aborted-delivery-#{delivery.id}"
        )
        raise result.error if result.failure?

        delivery.update_columns(
          status: "failed", failure_code: "campaign_aborted", failed_at: Time.current,
          updated_at: Time.current
        )
      end
    end

    def requeue_sending_campaigns
      Campaign.where(status: "sending").where(<<~SQL.squish, Time.current).order(:id).limit(BATCH_SIZE).pluck(:id)
        EXISTS (
          SELECT 1 FROM messaging_campaign_deliveries deliveries
          WHERE deliveries.campaign_id = messaging_campaigns.id
            AND deliveries.status = 'pending'
            AND (deliveries.next_attempt_at IS NULL OR deliveries.next_attempt_at <= ?)
        )
        OR EXISTS (
          SELECT 1 FROM messaging_campaign_recipients recipients
          WHERE recipients.campaign_id = messaging_campaigns.id
            AND recipients.eligibility_status IN ('eligible', 'suppressed')
            AND NOT EXISTS (
              SELECT 1 FROM messaging_campaign_deliveries claimed
              WHERE claimed.campaign_recipient_id = recipients.id
            )
        )
        OR (
          NOT EXISTS (
            SELECT 1 FROM messaging_campaign_deliveries active_deliveries
            WHERE active_deliveries.campaign_id = messaging_campaigns.id
              AND active_deliveries.status IN ('pending', 'processing')
          )
          AND NOT EXISTS (
            SELECT 1 FROM messaging_campaign_recipients unclaimed
            WHERE unclaimed.campaign_id = messaging_campaigns.id
              AND unclaimed.eligibility_status IN ('eligible', 'suppressed')
              AND NOT EXISTS (
                SELECT 1 FROM messaging_campaign_deliveries claimed
                WHERE claimed.campaign_recipient_id = unclaimed.id
              )
          )
          AND NOT EXISTS (
            SELECT 1 FROM messaging_campaign_credit_allocations allocated
            JOIN messaging_credit_reservations holds ON holds.id = allocated.credit_reservation_id
            WHERE allocated.campaign_id = messaging_campaigns.id
              AND allocated.status = 'allocated'
              AND holds.source_type = 'Messaging::Campaign'
          )
        )
      SQL
        .each { |campaign_id| FanoutCampaignJob.perform_later(campaign_id) }
    end

    def finalize_terminal_holds
      CreditReservation.joins(
        "INNER JOIN messaging_campaigns ON messaging_campaigns.id = messaging_credit_reservations.source_id"
      ).where(
        source_type: "Messaging::Campaign", status: "reserved", messaging_campaigns: { status: %w[canceled failed] }
      ).where.not(
        id: CampaignCreditAllocation.where(status: "allocated").select(:credit_reservation_id)
      ).order(:id).limit(BATCH_SIZE).pluck(
        "messaging_credit_reservations.id", "messaging_campaigns.status"
      ).each do |hold_id, campaign_status|
        result = Campaigns::CreditHolds::Finalize.call(
          reservation: CreditReservation.find(hold_id),
          resolution_code: campaign_status == "failed" ? "campaign_failed" : "campaign_aborted"
        )
        raise result.error if result.failure?
      end
    end

    def stale_processing?(delivery)
      delivery.status == "processing" && delivery.claimed_at.present? && delivery.claimed_at <= CLAIM_TIMEOUT.ago
    end

    def terminal_campaign?(campaign)
      campaign.status.in?(TERMINAL_CAMPAIGN_STATUSES)
    end

    def resume_preparing_snapshots
      CampaignAudienceSnapshot.where(status: "preparing").order(:updated_at, :id).limit(BATCH_SIZE).pluck(:id)
        .each { |snapshot_id| PrepareCampaignAudienceJob.perform_later(snapshot_id) }
    end
  end
end
