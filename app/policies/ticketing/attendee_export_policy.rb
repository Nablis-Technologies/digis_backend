# frozen_string_literal: true

module Ticketing
  # Requires current event authority; sensitive fields have additional grants.
  class AttendeeExportPolicy < Core::ApplicationPolicy
    REQUEST_PERMISSION = "attendee_export.request"
    CONTACT_PERMISSION = "attendee_export.contact"

    FIELDS = %i[
      id event_id requested_by_id status row_mode format_version field_set_digest
      filter_digest reason_code data_cutoff_at row_count file_sha256 digest_key_version
      attempt_count processing_started_at ready_at failed_at expiring_at expired_at
      expires_at last_download_authorized_at failure_code created_at updated_at
    ].freeze

    VISIBILITY = {
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      download_authorizations: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } }
    }.freeze

    def create?
      requester? && currently_authorized? && valid_contract?
    end

    def show?
      visible_to_actor? && currently_authorized?
    end

    def download_authorizations?
      visible_to_actor? && currently_authorized? && record.status != "expired"
    end

    private

    def requester?
      user.present? && record.requested_by_id == user.id
    end

    def visible_to_actor?
      user.present? && (requester? || platform_admin?)
    end

    def currently_authorized?
      record.event.present? && Events::AuthorizationResolver.can_manage_catalog?(user, record.event) &&
        fields_authorized?
    end

    def valid_contract?
      return false unless record.valid?

      fields_authorized?
    end

    def fields_authorized?
      return false unless user
      if record.status == "expired" && record.field_keys.nil? && record.filters.nil?
        return user.has_permission?(REQUEST_PERMISSION) && platform_admin?
      end

      result = Exports::FieldRegistry.resolve(
        event: record.event,
        selectors: record.field_keys,
        row_mode: record.row_mode
      )
      return false if result.failure?

      result.value.all? { |definition| field_authorized?(definition.fetch(:authorization)) }
    end

    def field_authorized?(authorization)
      case authorization
      when :event_manager
        true
      when CONTACT_PERMISSION
        user.has_permission?(CONTACT_PERMISSION) || tenant_contact_manager?
      else
        user.has_permission?(authorization)
      end
    end

    def tenant_contact_manager?
      memberships = Organizations::Membership.active.where(user_id: user.id, role: %w[owner admin])
      primary_organization = memberships.where(organization_id: record.event.organization_id)
      co_organizer_ids = Events::EventOrganization
        .where(event_id: record.event_id, type: "co_organizer", status: "active")
        .select(:organization_id)

      primary_organization.or(memberships.where(organization_id: co_organizer_ids)).exists?
    end

    def platform_admin?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")
    end
  end
end
