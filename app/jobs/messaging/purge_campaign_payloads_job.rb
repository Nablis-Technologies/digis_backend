# frozen_string_literal: true

module Messaging
  # Erases expired campaign content and contact material while preserving
  # aggregate status, quote, delivery, and credit evidence.
  class PurgeCampaignPayloadsJob < ApplicationJob
    PURGE_AFTER = 90.days
    BATCH_SIZE = 100

    queue_as :notifications

    def perform
      cutoff = PURGE_AFTER.ago
      Campaign.where(status: %w[completed canceled])
        .where("COALESCE(completed_at, canceled_at) <= ?", cutoff)
        .where(<<~SQL.squish)
          message_body_ciphertext IS NOT NULL OR message_subject_ciphertext IS NOT NULL OR EXISTS (
            SELECT 1 FROM messaging_campaign_recipients recipients
            WHERE recipients.campaign_id = messaging_campaigns.id
              AND (recipients.channel_address_ciphertext IS NOT NULL
                OR recipients.first_name_ciphertext IS NOT NULL
                OR recipients.last_name_ciphertext IS NOT NULL)
          )
        SQL
        .order(:id).limit(BATCH_SIZE).pluck(:id).each { |campaign_id| purge_campaign(campaign_id) }
      purge_contact_entries(cutoff)
      purge_import_blobs(cutoff)
    end

    private

    def purge_campaign(campaign_id)
      Campaign.where(id: campaign_id).update_all(
        message_subject_ciphertext: nil, message_body_ciphertext: nil, updated_at: Time.current
      )
      CampaignRecipient.where(campaign_id:).update_all(
        channel_address_ciphertext: nil, first_name_ciphertext: nil, last_name_ciphertext: nil,
        updated_at: Time.current
      )
    end

    def purge_contact_entries(cutoff)
      CampaignContactListEntry.transaction do
        ids = CampaignContactListEntry.joins(:campaign_contact_list)
          .where("messaging_campaign_contact_list_entries.updated_at <= ?", cutoff)
          .where(
            "messaging_campaign_contact_list_entries.status = :removed OR messaging_campaign_contact_lists.status = :archived",
            removed: "removed", archived: "archived"
          ).where(<<~SQL.squish)
            phone_number_ciphertext IS NOT NULL OR email_ciphertext IS NOT NULL OR
            first_name_ciphertext IS NOT NULL OR last_name_ciphertext IS NOT NULL
          SQL
          .order(:id).limit(BATCH_SIZE).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
        CampaignContactListEntry.where(id: ids).update_all(
          phone_number_ciphertext: nil, email_ciphertext: nil, first_name_ciphertext: nil,
          last_name_ciphertext: nil, updated_at: Time.current
        ) if ids.any?
      end
    end

    def purge_import_blobs(cutoff)
      CampaignContactListImport.transaction do
        CampaignContactListImport.where("updated_at <= ?", cutoff).where(<<~SQL.squish)
          EXISTS (
            SELECT 1 FROM active_storage_attachments attachments
            WHERE attachments.record_type = 'Messaging::CampaignContactListImport'
              AND attachments.record_id = messaging_campaign_contact_list_imports.id
              AND attachments.name IN ('file', 'rejected_report')
          )
        SQL
          .includes(:file_attachment, :rejected_report_attachment)
          .order(:id).limit(BATCH_SIZE).lock("FOR UPDATE SKIP LOCKED").each do |import|
          import.file.purge_later if import.file.attached?
          import.rejected_report.purge_later if import.rejected_report.attached?
          import.update_columns(updated_at: Time.current)
        end
      end
    end
  end
end
