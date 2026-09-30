# frozen_string_literal: true

module Orders
  # Owns the sellability rule for event dates used by checkout quotes and
  # orders. Scheduled dates must still be ahead of the operation timestamp.
  class EventDateEligibility
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

    def self.error_for(event:, event_date_ids:, at:)
      ids = Array(event_date_ids).map(&:to_s).uniq
      return unavailable unless ids.all? { |id| id.match?(UUID_PATTERN) }

      if ids.empty?
        return unless event.event_dates.exists?
        return if eligible_dates_exist?(event, at)

        return unavailable
      end

      dates = event.event_dates.where(id: ids).index_by { |date| date.id.to_s }
      return unavailable unless dates.size == ids.size
      return unavailable unless ids.all? { |id| sellable?(dates.fetch(id), at) }

      nil
    end

    def self.eligible_dates_exist?(event, at)
      event.event_dates.where(status: "scheduled").where("starts_at > ?", at).exists?
    end
    private_class_method :eligible_dates_exist?

    def self.sellable?(date, at)
      date.status == "scheduled" && date.starts_at > at
    end
    private_class_method :sellable?

    def self.unavailable
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.event_date_unavailable"),
        code: "event_date_unavailable",
        status: :conflict
      )
    end
    private_class_method :unavailable
  end
end
