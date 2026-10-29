# frozen_string_literal: true

module Messaging
  # Safe read projection for organization ledger evidence. Sensitive request
  # digests and audit metadata stay server-side.
  class CreditLedgerEntrySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :credit_account_id, :rate_version_id, :entry_type, :quantity,
      :available_delta, :reference_type, :reference_id, :created_at
  end
end
