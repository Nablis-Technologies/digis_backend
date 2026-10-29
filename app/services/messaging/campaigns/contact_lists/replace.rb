# frozen_string_literal: true

require "set"

module Messaging
  module Campaigns
    module ContactLists
      # Replaces a list after an explicit confirmation and version bump.
      class Replace < Core::BaseService
        include CommandSupport

        def initialize(list:, rows:, actor:, confirm:, idempotency_key:)
          @list = list
          @rows = rows
          @actor = actor
          @confirm = confirm == true
          @raw_idempotency_key = idempotency_key
        end

        def call
          return failure_for(:contact_list_replace_confirmation_required) unless @confirm

          key = Core::IdempotencyKey.new(@raw_idempotency_key)
          rows = normalized_rows(@rows)
          valid, invalid = valid_rows(rows)
          return invalid if invalid

          digest = request_digest(operation: "replace", list: @list, rows: valid)
          audit_key = audit_key(operation: "replace", list: @list, key:)
          audit = existing_audit(audit_key:, request_digest: digest)
          return replay_result(list: @list, audit:) if audit

          ActiveRecord::Base.transaction do
            @list.lock!
            previous_count = @list.entries.where(status: "active").count
            @list.entries.delete_all
            unique = deduplicate(valid)
            unique.each { |row| @list.entries.create!(entry_attributes(row)) }
            @list.update!(version: @list.version + 1)
            record_audit!(audit_key:, action: "messaging.campaign_contact_list.replaced",
              list: @list, actor: @actor, request_digest: digest,
              changes: { "previous_count" => previous_count, "replacement_count" => unique.length })
          end
          success(@list)
        rescue ArgumentError => exception
          failure(Core::BusinessError.new(exception.message, code: "invalid_idempotency_key", status: :bad_request))
        rescue Core::Audit::Record::ReplayConflict => exception
          failure(Core::BusinessError.new(exception.message, code: "idempotency_conflict", status: :conflict))
        rescue ActiveRecord::RecordInvalid => exception
          failure_for(:contact_list_invalid, errors: exception.record.errors.to_hash)
        end

        private

        def deduplicate(rows)
          seen = Set.new
          rows.select do |row|
            digests = [ row[:phone_digest], row[:email_digest] ].compact
            next false if digests.any? { |digest| seen.include?(digest) }

            seen.merge(digests)
            true
          end
        end

        def entry_attributes(row)
          row.slice(:phone_number, :email, :first_name, :last_name, :phone_digest, :email_digest, :source)
        end
      end
    end
  end
end
