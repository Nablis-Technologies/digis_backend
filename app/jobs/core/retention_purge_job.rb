# frozen_string_literal: true

module Core
  class RetentionPurgeJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = Core::Retention::EraseEligibleBatch::DEFAULT_BATCH_SIZE
    MAX_BATCHES = 10

    def perform(limit = BATCH_SIZE)
      batch_limit = limit.to_i.clamp(1, Core::Retention::EraseEligibleBatch::MAX_BATCH_SIZE)
      totals = { answers: 0, revisions: 0, consents: 0, skipped: 0, errors: 0, processed: 0 }

      MAX_BATCHES.times do
        result = Core::Retention::EraseEligibleBatch.call(limit: batch_limit)
        return result if result.failure?

        totals.merge!(result.value) { |_key, total, value| total + value }
        break if result.value[:processed].to_i < batch_limit
      end

      Rails.logger.info("Retention purge completed: #{totals.inspect}")
      totals
    end
  end
end
