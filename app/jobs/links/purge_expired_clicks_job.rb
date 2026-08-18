# frozen_string_literal: true

module Links
  # Deletes privacy-limited click details past retention without touching the
  # link target or aggregate counter used for redirect click caps.
  class PurgeExpiredClicksJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 500
    MAX_BATCH_SIZE = 5_000
    RETENTION_DAYS = 90

    def perform(retention_days: RETENTION_DAYS, batch_size: BATCH_SIZE, now: Time.current)
      cutoff = now - normalized_retention_days(retention_days).days
      runner = lambda do
        deleted = 0

        Links::ShortLinkClick.where("clicked_at < ?", cutoff)
          .in_batches(of: normalized_batch_size(batch_size)) do |batch|
          deleted += batch.delete_all
        end

        deleted
      end
      deleted = defined?(Prosopite) ? Prosopite.pause(&runner) : runner.call

      { deleted: }
    end

    private

    def normalized_retention_days(value)
      value.to_i.clamp(1, 3_650)
    end

    def normalized_batch_size(value)
      value.to_i.clamp(1, MAX_BATCH_SIZE)
    end
  end
end
