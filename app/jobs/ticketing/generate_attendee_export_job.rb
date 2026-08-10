# frozen_string_literal: true

module Ticketing
  class GenerateAttendeeExportJob < ApplicationJob
    queue_as :exports

    def perform(attendee_export_id)
      Ticketing::Exports::Generate.call(attendee_export_id:)
    end
  end
end
