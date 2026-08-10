# frozen_string_literal: true

module Ticketing
  class PurgeAttendeeExportJob < ApplicationJob
    queue_as :exports

    def perform(attendee_export_id)
      Ticketing::Exports::Purge.call(attendee_export_id:)
    end
  end
end
