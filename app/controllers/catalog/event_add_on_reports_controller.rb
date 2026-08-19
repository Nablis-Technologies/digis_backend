# frozen_string_literal: true

module Catalog
  # Organizer-only read endpoint for immutable add-on sales/refund aggregates.
  # The query owns event isolation and the serializer exposes only aggregate
  # fields, so this controller never loads buyer, credential, or payout rows.
  class EventAddOnReportsController < Catalog::ApplicationController
    def index
      event = Events::Event.find(params[:event_id])
      authorize event, :index?, policy_class: Catalog::AddOnReportPolicy

      result = Catalog::AddOnSalesReport.call(event:, filters: report_filters)
      if result.success?
        render_success(
          data: result.value,
          serializer_options: { serializer: Catalog::AddOnSalesRowSerializer }
        )
      else
        render_error(
          result.error,
          status: result.error.status,
          code: result.error.code,
          errors: result.error.errors
        )
      end
    end

    private

    def report_filters
      params.permit(:type, :currency, :settlement_currency).to_h.symbolize_keys
    end
  end
end
