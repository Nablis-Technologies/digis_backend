# frozen_string_literal: true

module Events
  class StaffInvitationPolicy < Core::ApplicationPolicy
    def index? = manage_staff?
    def claim? = user.present?
    def create? = manage_staff?
    def resend? = Events::AuthorizationResolver.can_assign?(user, record.event, record.role)
    def revoke? = Events::AuthorizationResolver.can_assign?(user, record.event, record.role)

    VISIBILITY = {
      index: { default: { fields: %i[id event_id role contact_type masked_contact status delivery_status delivery_revision expires_at assignment_expires_at accepted_at revoked_at expired_at created_at], include: [] } },
      create: { default: { fields: %i[id event_id role contact_type masked_contact status delivery_status delivery_revision expires_at assignment_expires_at created_at], include: [] } },
      resend: { default: { fields: %i[id event_id role contact_type masked_contact status delivery_status delivery_revision expires_at assignment_expires_at created_at], include: [] } },
      revoke: { default: { fields: %i[id event_id role contact_type masked_contact status delivery_status delivery_revision expires_at assignment_expires_at revoked_at created_at], include: [] } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        event_ids = Events::EventPolicy::Scope.new(user, Events::Event).resolve.select(:id)
        scope.where(event_id: event_ids)
      end
    end

    private

    def manage_staff?
      Events::AuthorizationResolver.can_assign?(user, record.event, "staff")
    end
  end
end
