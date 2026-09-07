# frozen_string_literal: true

require "digest"

module Messaging
  module Campaigns
    module ContactLists
      # Shared normalization and audit-idempotency helpers for list commands.
      module CommandSupport
        private

        def normalized_rows(rows)
          Array(rows).map.with_index(1) do |row, row_number|
            normalized = normalize_row(row)
            normalized[:row_number] = row_number
            normalized
          end
        end

        def normalize_row(row)
          values = row.to_h.stringify_keys
          phone = ChannelAddress.normalize(channel: "sms", value: values["phone_number"])
          email = ChannelAddress.normalize(channel: "email", value: values["email"])
          errors = []
          errors << "phone_number_invalid" if values["phone_number"].present? && phone.blank?
          errors << "email_invalid" if values["email"].present? && email.present? && !email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
          errors << "contact_required" if phone.blank? && email.blank?

          {
            phone_number: phone,
            email: email.presence,
            phone_digest: phone_digest(phone),
            email_digest: email_digest(email),
            first_name: values["first_name"].to_s.strip.presence,
            last_name: values["last_name"].to_s.strip.presence,
            source: values["source"].to_s.strip.presence || "manual",
            errors:
          }
        end

        def phone_digest(value)
          ChannelAddress.digest(channel: "sms", value:)
        end

        def email_digest(value)
          ChannelAddress.digest(channel: "email", value:)
        end

        def request_digest(operation:, list:, rows:)
          payload = rows.map do |row|
            row.slice(:phone_digest, :email_digest, :first_name, :last_name, :source)
          end
          Core::KeyedDigest.digest(
            namespace: "messaging-campaign-contact-list-#{operation}",
            value: "#{list.id}:#{ActiveSupport::JSON.encode(payload)}"
          )
        end

        def audit_key(operation:, list:, key:)
          "messaging-campaign-contact-list-#{operation}-#{list.id}-#{key.digest}"
        end

        def existing_audit(audit_key:, request_digest:)
          audit = Core::AuditLog.find_by(audit_key:)
          return if audit.nil?
          return audit if audit.metadata.to_h["request_digest"] == request_digest

          raise Core::Audit::Record::ReplayConflict, I18n.t("core.errors.audit_replay_conflict")
        end

        def record_audit!(audit_key:, action:, list:, actor:, request_digest:, changes: {})
          result = Core::Audit::Record.call(
            audit_key:,
            action:,
            auditable_type: list.class.name,
            auditable_id: list.id,
            actor_type: actor.class.name,
            actor_id: actor.id,
            audited_changes: changes,
            metadata: { "request_digest" => request_digest, "list_id" => list.id }
          )
          raise result.error if result.failure?

          result.value
        end

        def failure_for(key, status: :unprocessable_entity, errors: nil)
          failure(
            Core::BusinessError.new(
              I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:
            )
          )
        end

        def replay_result(list:, audit:)
          return unless audit

          success(list)
        end

        def valid_rows(rows)
          invalid = rows.select { |row| row[:errors].any? }
          return [ rows, nil ] if invalid.empty?

          [ rows, failure_for(:contact_list_row_invalid, errors: invalid.map { |row| row.slice(:row_number, :errors) }) ]
        end
      end
    end
  end
end
