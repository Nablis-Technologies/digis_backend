# frozen_string_literal: true

module Admin
  module Messaging
    class CreditAdjustmentPolicy < Core::ApplicationPolicy
      def create? = user&.super_admin? || user&.has_permission?("messaging_credit_adjustment.create")

      VISIBILITY = {
        create: { admin: { fields: :all, include: :all }, default: { fields: [], include: [] } }
      }.freeze
    end
  end
end
