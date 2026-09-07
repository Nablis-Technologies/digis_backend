# frozen_string_literal: true

module Messaging
  module Campaigns
    module ContactLists
      # Adds one entry through the same append validation/idempotency path.
      class AddEntry < Core::BaseService
        def self.call(list:, row:, actor:, idempotency_key:)
          Append.call(list:, rows: [ row ], actor:, idempotency_key:)
        end
      end
    end
  end
end
