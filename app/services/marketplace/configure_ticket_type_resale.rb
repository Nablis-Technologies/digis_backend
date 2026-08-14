# frozen_string_literal: true

module Marketplace
  # Persists the organizer's ticket-type resale policy under a row lock. The
  # disabled state always clears cap fields, and fixed caps must match the
  # event settlement currency before the policy can be saved.
  class ConfigureTicketTypeResale < Core::BaseService
    ATTRIBUTES = %i[
      resale_enabled resale_cutoff_seconds_before_start resale_price_cap_type
      resale_fixed_cap_minor resale_fixed_cap_currency resale_percentage_cap_bps
      max_completed_resales
    ].freeze

    def initialize(ticket_type:, attributes:)
      @ticket_type = ticket_type
      @attributes = attributes.to_h.symbolize_keys.slice(*ATTRIBUTES)
      normalize_cap_attributes
    end

    def call
      ActiveRecord::Base.transaction do
        locked_ticket_type = Ticketing::TicketType
          .includes(event_product: :event)
          .lock
          .find(@ticket_type.id)

        locked_ticket_type.assign_attributes(@attributes)
        clear_cap_fields_when_disabled(locked_ticket_type)

        return failure_for("resale_fixed_cap_currency_mismatch") if fixed_currency_mismatch?(locked_ticket_type)

        locked_ticket_type.save!
        success(locked_ticket_type)
      end
    rescue ActiveRecord::RecordNotFound
      failure_for("invalid_ticket_type")
    rescue ActiveRecord::RecordInvalid => error
      failure_for("invalid_resale_policy", errors: error.record.errors.to_hash)
    end

    private

    def clear_cap_fields_when_disabled(ticket_type)
      return if ticket_type.resale_enabled

      ticket_type.resale_price_cap_type = nil
      ticket_type.resale_fixed_cap_minor = nil
      ticket_type.resale_fixed_cap_currency = nil
      ticket_type.resale_percentage_cap_bps = nil
    end

    def normalize_cap_attributes
      if @attributes.key?(:resale_price_cap_type)
        @attributes[:resale_price_cap_type] = @attributes[:resale_price_cap_type].to_s.downcase.presence
      end
      if @attributes.key?(:resale_fixed_cap_currency)
        @attributes[:resale_fixed_cap_currency] = @attributes[:resale_fixed_cap_currency].to_s.upcase.presence
      end
    end

    def fixed_currency_mismatch?(ticket_type)
      ticket_type.resale_enabled &&
        ticket_type.resale_price_cap_type == "fixed" &&
        ticket_type.resale_fixed_cap_currency.present? &&
        ticket_type.resale_fixed_cap_currency != ticket_type.event_product.event.currency
    end

    def failure_for(code, errors: nil)
      failure Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{code}"),
        code:,
        status: :unprocessable_entity,
        errors:
      )
    end
  end
end
