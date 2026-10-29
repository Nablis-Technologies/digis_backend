# frozen_string_literal: true

module Messaging
  class CreditLedgerEntryPolicy < Core::ApplicationPolicy
    FIELDS = %i[id credit_account_id rate_version_id entry_type quantity available_delta reference_type reference_id created_at].freeze

    def index? = user.present?

    VISIBILITY = {
      index: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } }
    }.freeze
  end
end
