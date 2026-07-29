# frozen_string_literal: true

module Ticketing
  class TicketTypeSerializer < ActiveModel::Serializer
    attributes :id, :event_product_id, :approval_mode, :audience, :date_selection,
               :delegation_enabled, :delegation_validation_mode, :entry_validation_mode,
               :transferable, :transfer_cutoff_seconds_before_start,
               :admissions_per_unit, :resale_enabled, :resale_price_cap_type,
               :resale_fixed_cap_currency, :resale_fixed_cap_minor,
               :resale_percentage_cap_bps, :resale_cutoff_seconds_before_start,
               :max_completed_resales, :max_packages_per_user, :waitlist_enabled,
               :created_at, :updated_at
  end
end
