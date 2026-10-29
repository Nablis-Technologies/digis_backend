# frozen_string_literal: true

module Messaging
  # Materializes one campaign audience outside the request transaction.
  class PrepareCampaignAudienceJob < ApplicationJob
    BATCH_SIZE = 500
    MAX_CANDIDATES = 10_000

    queue_as :notifications

    def perform(snapshot_id)
      snapshot = CampaignAudienceSnapshot.includes(campaign: %i[organization event]).find(snapshot_id)
      return if snapshot.status == "ready"

      snapshot.update!(status: "preparing", started_at: snapshot.started_at || Time.current)
      candidates = resolve_candidates(snapshot)
      raise audience_too_large if candidates.length > MAX_CANDIDATES

      snapshot.update!(total_count: candidates.length) if snapshot.total_count.zero?
      write_batches(snapshot, candidates)
      snapshot.update!(status: "ready", completed_at: Time.current, next_cursor: nil)
    rescue ActiveRecord::RecordNotFound
      nil
    rescue Core::BusinessError => exception
      mark_failed(snapshot_id, exception.code)
    rescue StandardError => exception
      mark_failed(snapshot_id, exception.message.to_s.first(500))
      raise
    end

    private

    def resolve_candidates(snapshot)
      campaign = snapshot.campaign
      result = Campaigns::Audience::Resolve.call(
        organization: campaign.organization,
        channel: campaign.channel,
        sources: snapshot.source_spec.to_h["sources"] || []
      )
      raise result.error if result.failure?

      result.value
    end

    def write_batches(snapshot, candidates)
      candidates = candidates.drop_while do |candidate|
        snapshot.next_cursor.present? && candidate.channel_address_digest <= snapshot.next_cursor
      end

      candidates.each_slice(BATCH_SIZE) do |batch|
        suppressed = suppression_map(snapshot.campaign, batch)
        rows = batch.map do |candidate|
          eligibility_status, reason = eligibility_for(snapshot.campaign, candidate, suppressed)
          recipient_attributes(snapshot, candidate, quantity_for(snapshot.campaign, candidate), eligibility_status, reason)
        end
        CampaignRecipient.insert_all(rows, unique_by: %i[campaign_id channel_address_digest])
        update_progress(snapshot, batch.last.channel_address_digest)
      end
    end

    def update_progress(snapshot, cursor)
      recipients = CampaignRecipient.where(audience_snapshot_id: snapshot.id)
      snapshot.update_columns(
        processed_count: recipients.count,
        eligible_quantity: recipients.where(eligibility_status: "eligible").sum(:quantity),
        next_cursor: cursor,
        updated_at: Time.current
      )
    end

    def recipient_attributes(snapshot, candidate, quantity, status, reason)
      recipient = CampaignRecipient.new(
        campaign_id: snapshot.campaign_id,
        audience_snapshot_id: snapshot.id,
        channel: candidate.channel,
        channel_address_digest: candidate.channel_address_digest,
        channel_address: candidate.channel_address,
        first_name: candidate.first_name,
        last_name: candidate.last_name,
        source_type: candidate.source_type,
        source_id: candidate.source_id,
        historical_basis: candidate.historical_basis,
        eligibility_status: status,
        eligibility_reason: reason,
        quantity:
      )
      recipient.attributes.slice(
        "campaign_id", "audience_snapshot_id", "channel", "channel_address_digest",
        "channel_address_ciphertext", "first_name_ciphertext", "last_name_ciphertext",
        "source_type", "source_id", "historical_basis", "eligibility_status",
        "eligibility_reason", "quantity"
      ).merge("created_at" => Time.current, "updated_at" => Time.current)
    end

    def quantity_for(campaign, candidate)
      body = Campaigns::Templates::Interpolator.call(
        campaign.message_body, values: Campaigns::Templates::Context.values(campaign:, recipient: candidate),
        escape_values: false
      )
      Campaigns::Templates::SmsSegmentCounter.units_for(channel: campaign.channel, body:)
    end

    def suppression_map(campaign, candidates)
      digests = candidates.map(&:channel_address_digest)
      CampaignSuppression.where(channel: campaign.channel, channel_address_digest: digests)
        .where(organization_id: [ campaign.organization_id, nil ]).pluck(:organization_id, :channel_address_digest)
        .to_set
    end

    def eligibility_for(campaign, candidate, suppressed)
      return [ "eligible", nil ] unless suppressed.include?([ nil, candidate.channel_address_digest ]) ||
        suppressed.include?([ campaign.organization_id, candidate.channel_address_digest ])

      reason = suppressed.include?([ nil, candidate.channel_address_digest ]) ? "global_suppression" : "organization_suppression"
      [ "suppressed", reason ]
    end

    def mark_failed(snapshot_id, code)
      CampaignAudienceSnapshot.where(id: snapshot_id).update_all(status: "failed", failure_code: code, completed_at: Time.current)
    end

    def audience_too_large
      Core::BusinessError.new(
        I18n.t("messaging.errors.campaign_audience_too_large"),
        code: "campaign_audience_too_large", status: :unprocessable_entity
      )
    end
  end
end
