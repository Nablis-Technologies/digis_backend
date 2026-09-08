# frozen_string_literal: true

module Ticketing
  # Signed-link ticket projection. It contains only admission context and the
  # active bearer QR value; owner, payment, consent, and account controls stay
  # outside this unauthenticated boundary.
  class PublicTicketViewSerializer < ActiveModel::Serializer
    attributes :id, :status, :unit_number, :admissions_per_unit_snapshot,
               :credential_mode, :credential_version, :event, :product,
               :event_dates, :credentials

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
      { id: object.event_product.id, name: object.event_product.name, type: object.event_product.type }
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

    def credentials
      generation = object.current_credential_generation
      return [] unless generation&.status == "active"

      generation.credentials
        .select { |credential| credential.status == "active" }
        .sort_by(&:id)
        .map { |credential| TicketWalletCredentialSerializer.new(credential, deliver_secret: true).attributes }
    end

    private

    def venue_summary(venue)
      return unless venue

      { id: venue.id, name: venue.name, city: venue.city }
    end
  end
end
