# frozen_string_literal: true

module Admin
  module Messaging
    class CreditRateVersionPolicy < Core::ApplicationPolicy
      def index? = allowed?(:index)
      def show? = allowed?(:show)
      def create? = allowed?(:create)
      def activate? = allowed?(:activate)
      def retire? = allowed?(:retire)

      VISIBILITY = {
        index: { admin: { fields: :all, include: :all }, default: { fields: [], include: [] } },
        show: { admin: { fields: :all, include: :all }, default: { fields: [], include: [] } },
        create: { admin: { fields: :all, include: :all }, default: { fields: [], include: [] } },
        activate: { admin: { fields: :all, include: :all }, default: { fields: [], include: [] } },
        retire: { admin: { fields: :all, include: :all }, default: { fields: [], include: [] } }
      }.freeze

      class Scope < Core::ApplicationPolicy::Scope
        def resolve
          return scope.none unless user
          return scope.all if user.super_admin? || user.has_permission?("messaging_credit_rate.index")

          scope.none
        end
      end

      private

      def allowed?(action)
        user&.super_admin? || user&.has_permission?("messaging_credit_rate.#{action}")
      end
    end
  end
end
