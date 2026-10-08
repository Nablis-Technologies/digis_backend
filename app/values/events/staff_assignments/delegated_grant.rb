# frozen_string_literal: true

module Events
  module StaffAssignments
    # Internal proof passed by a trusted domain command that consumed an
    # event-scoped invitation after its creator was authorized at issuance.
    DelegatedGrant = Data.define(:event_id, :role, :grantor_id, :source_type, :source_id, :issued_at) do
      def valid?
        event_id.present? &&
          role.to_s == "scanner" &&
          grantor_id.present? &&
          source_type == "Ticketing::ScannerInvitation" &&
          source_id.present? &&
          issued_at.present?
      end

      def valid_for?(event:, role:, at: Time.current)
        valid? &&
          event_id.to_s == event.id.to_s &&
          self.role.to_s == role.to_s &&
          issued_at <= at
      end
    end
  end
end
