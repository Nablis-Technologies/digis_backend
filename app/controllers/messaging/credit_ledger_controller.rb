# frozen_string_literal: true

module Messaging
  # Provides an organization-scoped, read-only view of append-only credit
  # evidence. Filtering and ordering remain allowlisted to avoid exposing
  # internal provider or idempotency metadata.
  class CreditLedgerController < Messaging::ApplicationController
    def index
      organization = Organizations::Organization.find(params[:organization_id])
      authorize CreditAccount.new(organization:), :index?
      @clazz = CreditLedgerEntry
      account_ids = CreditAccount.where(organization:).select(:id)
      entries = CreditLedgerEntry.where(credit_account_id: account_ids)
        .includes(:rate_version)
      entries = filter_records(entries)
      entries = apply_ordering(entries)
      total_count = entries.count if paginated_request?
      entries = paginated_request? ? apply_pagination(entries) : entries.limit(default_per_page)
      render_success(
        data: entries,
        serializer_options: { serializer: CreditLedgerEntrySerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    private

    def allowed_order_columns
      %w[id entry_type quantity available_delta reference_type created_at]
    end

    def serializer_profile
      { index: { fields: CreditLedgerEntryPolicy::FIELDS, include: [] } }
    end
  end
end
