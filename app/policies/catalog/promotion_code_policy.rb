# frozen_string_literal: true

module Catalog
  # Organizer-scoped policy for promotion-code metadata and explicit reveals.
  class PromotionCodePolicy < Core::ApplicationPolicy
    def index?  = manageable_events.exists?
    def show?   = manageable_promotion?
    def create? = manageable_promotion?
    def reveal? = manageable_promotion?

    VISIBILITY = {
      index: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      show: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      create: {
        default: { fields: :all, include: [] },
        admin: { fields: :all, include: :all }
      },
      reveal: {
        default: { fields: [], include: [] },
        admin: { fields: :all, include: :all }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        manageable_events = Events::AuthorizationResolver.manageable_catalog_events(user)
        scope.joins(:promotion).where(catalog_promotions: { event_id: manageable_events.select(:id) })
      end
    end

    private

    def manageable_promotion?
      record.promotion.present? && Events::AuthorizationResolver.can_manage_catalog?(user, record.promotion.event)
    end

    def manageable_events
      Events::AuthorizationResolver.manageable_catalog_events(user)
    end
  end
end
