# frozen_string_literal: true

module Events
  # Periodic sweep that removes orphaned event_media rows whose image was never
  # successfully attached, keeping the table free of rows with no blob.
  class CleanupUnattachedEventMediaJob < ApplicationJob
    queue_as :default

    def perform
      Events::EventMedia.where.missing(:file_attachment).find_each(&:destroy!)
    end
  end
end
