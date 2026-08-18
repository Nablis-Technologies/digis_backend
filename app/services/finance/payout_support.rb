# frozen_string_literal: true

module Finance
  # Shared payout invariants. Build and dispatch both call these checks so a
  # payout cannot become valid merely because its provider call happens later.
  module PayoutSupport
    DEFAULT_MATURITY_BUFFER = 7.days
    NEGATIVE_TYPES = %w[platform_fee processing_fee refund chargeback adjustment].freeze
    POSITIVE_TYPES = %w[sale adjustment].freeze

    private

    def finance_error(key, code: key, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:)
    end

    def normalize_currency(currency)
      currency.to_s.strip.upcase
    end

    def matured_event?(event, at:)
      return false unless event.status == "completed" && event.completed_at.present?
      return false if event.completed_at + DEFAULT_MATURITY_BUFFER > at
      blocked_dates = if event.event_dates.loaded?
        event.event_dates.any? { |event_date| event_date.status.in?(%w[postponed suspended cancelled]) }
      else
        event.event_dates.where(status: %w[postponed suspended cancelled]).exists?
      end
      return false if blocked_dates

      true
    end

    def positive_entry_eligible?(entry, at:)
      entry.amount_minor.positive? && entry.type.in?(POSITIVE_TYPES) &&
        entry.event.present? && matured_event?(entry.event, at:)
    end

    def payout_entry_description
      I18n.t("finance.ledger.descriptions.payout")
    end

    def available_allocated_amounts(entry_ids)
      Finance::PayoutAllocation.where(
        ledger_entry_id: entry_ids, status: %w[reserved consumed]
      ).group(:ledger_entry_id).sum(:amount_minor).transform_values(&:abs)
    end

    def organization_lock(organization_id)
      Organizations::Organization.lock.find(organization_id)
    end

    # PostgreSQL advisory transaction locks provide a real organization/currency
    # scope even when no payout or policy row exists yet. The organization row
    # lock remains useful for referential consistency, but this key prevents
    # two currencies or two first-time builders from racing on empty scope.
    def payout_scope_lock(organization_id:, currency:)
      connection = ActiveRecord::Base.connection
      scope_key = connection.quote("finance-payout:#{organization_id}:#{currency}")
      connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{scope_key}, 0))")
    end

    def error_for_invalid_record(key, code: key)
      failure(finance_error(key, code:, status: :conflict))
    end
  end
end
