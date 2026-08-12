# frozen_string_literal: true

module Ticketing
  # Owner-only policy for package lifecycle commands. Organizer/manager
  # overrides are intentionally deferred until the later suspension and
  # operational-management tasks define their audit and scope rules.
  class TicketPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id event_id event_product_id unit_number admissions_per_unit_snapshot owner_user_id
      current_acquisition_type current_acquisition_product_value_minor current_acquisition_currency
      completed_resale_count credential_mode credential_version status issued_at created_at updated_at
    ].freeze

    def show? = owner?
    def delegate? = owner?
    def cancel_delegation? = owner?
    def reassign_slot? = owner?
    def transfer? = owner?

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      delegate: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      cancel_delegation: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      reassign_slot: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      transfer: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        scope.where(owner_user_id: user.id)
      end
    end

    private

    def owner?
      user.present? && record.owner_user_id == user.id
    end
  end
end
