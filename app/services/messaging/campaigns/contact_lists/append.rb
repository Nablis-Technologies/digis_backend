# frozen_string_literal: true

module Messaging
  module Campaigns
    module ContactLists
      # Appends only new normalized contact addresses to a reusable list.
      class Append < Core::BaseService
        include CommandSupport

        def initialize(list:, rows:, actor:, idempotency_key:)
          @list = list
          @rows = rows
          @actor = actor
          @raw_idempotency_key = idempotency_key
        end

        def call
          key = Core::IdempotencyKey.new(@raw_idempotency_key)
          rows = normalized_rows(@rows)
          valid, invalid = valid_rows(rows)
          return invalid if invalid

          digest = request_digest(operation: "append", list: @list, rows: valid)
          audit_key = audit_key(operation: "append", list: @list, key:)
          audit = existing_audit(audit_key:, request_digest: digest)
          return replay_result(list: @list, audit:) if audit

          ActiveRecord::Base.transaction do
            @list.lock!
            existing = @list.entries.where(status: "active").pluck(:phone_digest, :email_digest).flatten.compact.to_set
            valid.each do |row|
              next if [ row[:phone_digest], row[:email_digest] ].compact.any? { |value| existing.include?(value) }

              @list.entries.create!(entry_attributes(row))
              existing.merge([ row[:phone_digest], row[:email_digest] ].compact)
            end
            record_audit!(audit_key:, action: "messaging.campaign_contact_list.appended",
              list: @list, actor: @actor, request_digest: digest,
              changes: { "added_count" => valid.length })
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

        def entry_attributes(row)
          row.slice(:phone_number, :email, :first_name, :last_name, :phone_digest, :email_digest, :source)
        end
      end
    end
  end
end
