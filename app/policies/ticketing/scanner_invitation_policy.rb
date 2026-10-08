# frozen_string_literal: true

module Ticketing
  # Restricts scanner invitation management to event actors who can assign scanners.
  class ScannerInvitationPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id event_id organization_id masked_phone display_label organizer_note status delivery_status
      delivery_revision zone_mode selected_zone_ids starts_at ends_at expires_at pairing_code_expires_at
      paired_at created_at updated_at
    ].freeze

    def show?
      manage?
    end

    def create?
      return false unless record.respond_to?(:event)

      Events::AuthorizationResolver.can_assign?(user, record.event, "scanner")
    end

    def resend?
      manage?
    end

    def reset_pairing?
      manage?
    end

    def revoke?
      manage?
    end

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      resend: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      reset_pairing: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      revoke: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        event_ids = Events::AuthorizationResolver.manageable_catalog_events(user, Events::Event.all).select(:id)
        scope.where(event_id: event_ids)
      end
    end

    private

    def manage?
      Events::AuthorizationResolver.can_assign?(user, record.event, "scanner")
    end
  end
end
