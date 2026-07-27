# frozen_string_literal: true

module Events
  # Purges an Active Storage blob after its media row has been removed. Only
  # the blob id is enqueued, never the file or its URL.
  class PurgeEventMediaJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(blob_id)
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      blob&.purge
    end
  end
end
