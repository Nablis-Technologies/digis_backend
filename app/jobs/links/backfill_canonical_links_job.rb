# frozen_string_literal: true

require "set"

module Links
  # Creates one deterministic canonical link per existing event, ticket, and
  # organization. The job is safe to rerun because target uniqueness is
  # database-enforced and collision suffixes derive only from the target ID.
  class BackfillCanonicalLinksJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 500
    def perform(batch_size: BATCH_SIZE)
      totals = empty_totals
      return totals unless Rails.application.config.x.short_links.enabled

      each_target(batch_size:).each do |target_type, target, canonical_ids|
        status, collisions = backfill_target(target_type, target, canonical_ids:)
        totals[status] += 1
        totals[:collisions] += collisions
      end

      totals
    end

    private

    def each_target(batch_size:)
      return enum_for(__method__, batch_size:) unless block_given?

      Links::BackfillCanonical::TARGETS.each do |target_type, model|
        model.in_batches(of: normalized_batch_size(batch_size)) do |batch|
          canonical_ids = canonical_target_ids(target_type, batch)
          batch.each { |target| yield target_type, target, canonical_ids }
        end
      end
    end

    def backfill_target(target_type, target, canonical_ids:)
      result = Links::BackfillCanonical.call(target_type:, target:, canonical_ids:)
      return [ result.value.status, result.value.collisions ] if result.success?

      [ :failed, 0 ]
    end

    def canonical_target_ids(target_type, batch)
      Links::ShortLink
        .where(canonical: true, target_type:)
        .where(target_id: batch.select(:id))
        .pluck(:target_id)
        .to_set
    end

    def normalized_batch_size(value)
      value.to_i.clamp(1, BATCH_SIZE)
    end

    def empty_totals
      { created: 0, preserved: 0, collisions: 0, failed: 0 }
    end
  end
end
