# frozen_string_literal: true

module Messaging
  module Campaigns
    module ContactLists
      # Removes one saved entry without changing a launched campaign snapshot.
      class RemoveEntry < Core::BaseService
        def initialize(entry:, actor:, idempotency_key:)
          @entry = entry
          @actor = actor
          @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
        end

        def call
          @entry.update!(status: "removed") unless @entry.status == "removed"
          success(@entry)
        rescue ArgumentError => exception
          failure(Core::BusinessError.new(exception.message, code: "invalid_idempotency_key", status: :bad_request))
        end
      end
    end
  end
end
