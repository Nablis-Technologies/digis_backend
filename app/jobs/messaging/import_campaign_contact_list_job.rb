# frozen_string_literal: true

require "csv"
require "stringio"

module Messaging
  # Streams one bounded CSV import; only the import id crosses the queue.
  class ImportCampaignContactListJob < ApplicationJob
    include Campaigns::ContactLists::CommandSupport

    queue_as :notifications

    MAX_ROWS = 10_000
    BATCH_SIZE = 500
    REPORT_COLUMNS = %w[row_number phone_number email first_name last_name errors].freeze

    def perform(import_id)
      import = CampaignContactListImport.includes(:campaign_contact_list).find(import_id)
      return if import.status == "completed"

      import.update!(status: "processing", started_at: Time.current)
      counters = Hash.new(0)
      rejected = []

      ActiveRecord::Base.transaction do
        seen = existing_digests(import.campaign_contact_list)
        suppressed = suppression_digests(import.campaign_contact_list)
        accepted_rows = []
        import.file.open do |file|
          CSV.foreach(file.path, headers: true).with_index(2) do |row, row_number|
            raise RowLimitExceeded if row_number - 1 > MAX_ROWS

            process_row(import.campaign_contact_list, row, row_number, seen, suppressed, counters, rejected, accepted_rows)
          end
        end
        insert_entries(accepted_rows)
      end

      attach_report(import, rejected)
      import.update!(
        status: "completed",
        total_rows: counters[:total],
        accepted_rows: counters[:accepted],
        duplicate_rows: counters[:duplicate],
        invalid_rows: counters[:invalid],
        suppressed_rows: counters[:suppressed],
        missing_channel_rows: counters[:missing_channel],
        completed_at: Time.current
      )
    rescue RowLimitExceeded
      import.update!(status: "failed", error_detail: "contact_list_row_limit_exceeded", completed_at: Time.current)
    rescue CSV::MalformedCSVError, ActiveStorage::FileNotFoundError => exception
      import.update!(status: "failed", error_detail: exception.class.name, completed_at: Time.current)
    rescue StandardError => exception
      import.update!(status: "failed", error_detail: exception.message.to_s.first(500), completed_at: Time.current)
      raise
    end

    class RowLimitExceeded < StandardError; end

    private

    def existing_digests(list)
      {
        phone: list.entries.where(status: "active").where.not(phone_digest: nil).pluck(:phone_digest).to_set,
        email: list.entries.where(status: "active").where.not(email_digest: nil).pluck(:email_digest).to_set
      }
    end

    def suppression_digests(list)
      CampaignSuppression.where(organization_id: [ list.organization_id, nil ])
        .pluck(:channel, :channel_address_digest).to_set
    end

    def process_row(list, row, row_number, seen, suppressed, counters, rejected, accepted_rows)
      counters[:total] += 1
      normalized = normalize_row(row)
      errors = normalized.fetch(:errors)
      errors = [ "duplicate" ] if errors.empty? && duplicate?(normalized, seen)
      errors = [ "suppressed" ] if errors.empty? && suppressed?(normalized, suppressed)

      if errors.any?
        counter = if errors.first == "duplicate"
          :duplicate
        elsif errors.first == "suppressed"
          :suppressed
        else
          :invalid
        end
        counters[counter] += 1
        rejected << report_row(row, row_number, errors)
        return
      end

      accepted_rows << build_entry_attributes(list, normalized)
      if accepted_rows.length >= BATCH_SIZE
        insert_entries(accepted_rows)
        accepted_rows.clear
      end

      seen[:phone].add(normalized[:phone_digest]) if normalized[:phone_digest]
      seen[:email].add(normalized[:email_digest]) if normalized[:email_digest]
      counters[:accepted] += 1
    end

    def build_entry_attributes(list, normalized)
      entry = list.entries.build(
        phone_number: normalized[:phone_number],
        email: normalized[:email],
        first_name: normalized[:first_name],
        last_name: normalized[:last_name],
        phone_digest: normalized[:phone_digest],
        email_digest: normalized[:email_digest],
        source: "csv",
        status: "active"
      )
      raise ActiveRecord::RecordInvalid, entry unless entry.valid?

      entry.attributes_for_database.except("id").merge(
        "campaign_contact_list_id" => list.id,
        "created_at" => Time.current,
        "updated_at" => Time.current
      )
    end

    def insert_entries(rows)
      return if rows.empty?

      CampaignContactListEntry.insert_all(rows)
    end

    def duplicate?(row, seen)
      (row[:phone_digest] && seen[:phone].include?(row[:phone_digest])) ||
        (row[:email_digest] && seen[:email].include?(row[:email_digest]))
    end

    def suppressed?(row, suppressed)
      [ [ "sms", row[:phone_digest] ], [ "email", row[:email_digest] ] ].any? do |channel, digest|
        next false if digest.blank?

        suppressed.include?([ channel, digest ])
      end
    end

    def report_row(row, row_number, errors)
      values = row.to_h.stringify_keys
      REPORT_COLUMNS.index_with do |column|
        next row_number if column == "row_number"
        next errors.join(",") if column == "errors"

        sanitize_cell(values[column])
      end
    end

    def sanitize_cell(value)
      text = value.to_s
      text.match?(/\A[=+\-@]/) ? "'#{text}" : text
    end

    def attach_report(import, rows)
      return if rows.empty?

      csv = CSV.generate do |output|
        output << REPORT_COLUMNS
        rows.each { |row| output << REPORT_COLUMNS.map { |column| row.fetch(column) } }
      end
      import.rejected_report.attach(
        io: StringIO.new(csv), filename: "#{import.id}-rejected.csv", content_type: "text/csv"
      )
    end
  end
end
