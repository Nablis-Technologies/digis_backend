# frozen_string_literal: true

module Orders
  # Converts shared Events date eligibility into the checkout error contract.
  class EventDateEligibility
    def self.error_for(event:, event_date_ids:, at:)
      ids = Array(event_date_ids).map(&:to_s).uniq
      return unavailable unless Events::EventDateEligibility.valid_ids?(ids)

      snapshot = snapshot_for(event, ids, at)
      return if snapshot.eligible?(ids)

      unavailable
    end

    def self.snapshot_for(event, ids, at)
      return Events::EventDateEligibility.snapshot(event_dates: event.event_dates.where(id: ids).to_a, at:) if ids.present?

      has_dates = event.event_dates.exists?
      future_dates = event.event_dates.where(status: "scheduled").where("starts_at > ?", at).to_a
      Events::EventDateEligibility.snapshot(event_dates: future_dates, at:, has_dates:)
    end
    private_class_method :snapshot_for

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
