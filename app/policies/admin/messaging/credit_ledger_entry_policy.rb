# frozen_string_literal: true

module Admin
  module Messaging
    class CreditLedgerEntryPolicy < Core::ApplicationPolicy
      FIELDS = %i[id credit_account_id rate_version_id entry_type quantity available_delta reference_type reference_id created_at].freeze

      def create? = user&.super_admin? || user&.has_permission?("messaging_credit_adjustment.create")

      VISIBILITY = {
        create: { admin: { fields: FIELDS, include: [] }, default: { fields: [], include: [] } }
      }.freeze
    end
  end
end
