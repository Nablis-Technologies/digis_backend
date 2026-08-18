# frozen_string_literal: true

module Marketplace
  # Keeps buyer listing discovery separate from seller economics. A listing is
  # visible to a buyer only while active; the seller retains access to their
  # own terminal history for support and reconciliation.
  class ResaleListingPolicy < Core::ApplicationPolicy
    BUYER_FIELDS = %i[
      id event_id ticket_type_id status asking_amount_minor currency resale_cutoff_at fee_terms
      created_at updated_at
    ].freeze
    SELLER_FIELDS = (BUYER_FIELDS + %i[
      seller_user_id seller_acquisition_product_value_minor cap_type_snapshot fixed_cap_minor_snapshot
      percentage_cap_bps_snapshot calculated_cap_minor resale_count_before max_completed_resales_snapshot
      commercial_fee_component_id commercial_fee_schedule_version_id activated_at sold_at closed_at
    ]).freeze

    def index? = user.present?

    def show? = platform_admin? || seller? || (record.status == "active" && record.seller_user_id != user&.id)

    def create? = platform_admin? || owner_ticket?

    def purchase? = show? && record.status == "active" && record.seller_user_id != user&.id

    def cancel? = platform_admin? || (seller? && record.open?)

    VISIBILITY = {
      index: { default: { fields: BUYER_FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      show: { default: { fields: BUYER_FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      create: { default: { fields: SELLER_FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      purchase: { default: { fields: BUYER_FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      cancel: { default: { fields: SELLER_FIELDS, include: [] }, admin: { fields: :all, include: [] } }
    }.freeze

    def visible_attributes_for(record:, action:)
      return nil if platform_admin?
      return SELLER_FIELDS if seller_record?(record)

      super
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if platform_admin?

        scope.where(status: "active").or(scope.where(seller_user_id: user.id))
      end

      private

      def platform_admin?
        user.super_admin? || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")
      end
    end

    private

    def seller?
      seller_record?(record)
    end

    def seller_record?(target)
      target.respond_to?(:seller_user_id) && target.seller_user_id == user&.id
    end

    def owner_ticket?
      record.respond_to?(:owner_user_id) && record.owner_user_id == user&.id
    end

    def platform_admin?
      user&.super_admin? || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end
  end
end
