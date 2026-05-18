module Platform
  module Filterable
    extend ActiveSupport::Concern

    def filter_records(records)
      return records unless params[:q].present?
      return records unless records.respond_to?(:ransack)

      @q = records.ransack(params[:q])
      @q.result(distinct: true)
    rescue StandardError => error
      Rails.logger.warn("Ransack filter skipped: #{error.class} - #{error.message}")
      records
    end
  end
end
