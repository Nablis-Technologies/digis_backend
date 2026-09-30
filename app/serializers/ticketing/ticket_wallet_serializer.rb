# frozen_string_literal: true

module Ticketing
  # Owner-scoped wallet projection. It contains the context needed to present a
  # ticket while excluding payment, provider, and historical credential data.
  class TicketWalletSerializer < ActiveModel::Serializer
    attributes :id, :status, :unit_number, :admissions_per_unit_snapshot,
               :credential_mode, :credential_version, :event, :product,
               :ticket_type, :event_dates, :admission_slots, :credentials, :add_ons

    def event
      {
        id: object.event.id,
        slug: object.event.slug,
        title: object.event.title,
        timezone: object.event.timezone,
        currency: object.event.currency
      }
    end

    def product
      {
        id: object.event_product.id,
        name: object.event_product.name,
        type: object.event_product.type
      }
    end

    def ticket_type
      type = object.event_product.ticket_type
      return unless type

      {
        id: type.id,
        admissions_per_unit: type.admissions_per_unit,
        entry_validation_mode: type.entry_validation_mode,
        resale_enabled: type.resale_enabled,
        resale_price_cap_type: type.resale_price_cap_type,
        resale_fixed_cap_minor: type.resale_fixed_cap_minor,
        resale_fixed_cap_currency: type.resale_fixed_cap_currency,
        resale_percentage_cap_bps: type.resale_percentage_cap_bps,
        resale_price_cap_minor: calculate_resale_price_cap_minor(type),
        resale_cutoff_seconds_before_start: type.resale_cutoff_seconds_before_start,
        max_completed_resales: type.max_completed_resales
      }
    end

    def calculate_resale_price_cap_minor(type)
      return unless resale_cap_available?(type)

      result = Marketplace::CalculatePriceCap.call(
        cap_type: type.resale_price_cap_type,
        acquisition_product_value_minor: object.current_acquisition_product_value_minor,
        fixed_cap_minor: type.resale_fixed_cap_minor,
        percentage_cap_bps: type.resale_percentage_cap_bps
      )
      result.value.calculated_cap_minor if result.success?
    end

    def event_dates
      object.event_product.product_accesses.filter_map(&:event_date).uniq.sort_by(&:starts_at).map do |date|
        {
          id: date.id,
          name: date.name,
          starts_at: date.starts_at,
          ends_at: date.ends_at,
          status: date.status,
          venue: venue_summary(date.venue)
        }
      end
    end

    def admission_slots
      object.admission_slots.sort_by(&:position).map do |slot|
        { id: slot.id, position: slot.position, assignment_status: slot.assignment_status }
      end
    end

    def credentials
      generation = object.current_credential_generation
      return [] unless generation&.status == "active"

      object.current_credential_generation.credentials
        .select { |credential| credential.status == "active" }
        .sort_by(&:id)
        .map do |credential|
          TicketWalletCredentialSerializer.new(
            credential, deliver_secret: object.status == "active"
          ).attributes
        end
    end

    def add_ons
      order = object.order_item&.order
      return [] unless order

      order.order_items
        .reject { |item| item.type_snapshot == "ticket" }
        .map do |item|
          {
            id: item.id,
            name: item.name_snapshot,
            type: item.type_snapshot,
            quantity: item.quantity,
            unit_amount_minor: item.charge_unit_amount_minor
          }
        end
    end

    private

    def resale_cap_available?(type)
      return false unless type&.resale_enabled && object.status == "active"
      return false unless Ticketing::Ticket::PAID_ACQUISITION_TYPES.include?(object.current_acquisition_type)
      return false unless object.current_acquisition_product_value_minor.to_i.positive?

      object.current_acquisition_currency == object.event.currency
    end

    def venue_summary(venue)
      return unless venue

      { id: venue.id, name: venue.name, city: venue.city }
    end
  end
end
