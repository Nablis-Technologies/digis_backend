# frozen_string_literal: true

module Catalog
  module Public
    # Attendee-safe ticket policy fields. Organizer controls for transfer,
    # delegation, resale, and purchase limits stay off the public surface.
    class TicketTypeSerializer < ActiveModel::Serializer
      attributes :id, :event_product_id, :approval_mode, :audience,
                 :date_selection, :admissions_per_unit, :waitlist_enabled
    end
  end
end
