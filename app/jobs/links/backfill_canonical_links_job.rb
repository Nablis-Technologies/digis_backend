# frozen_string_literal: true

require "set"

module Links
  # Creates one deterministic canonical link per existing event, ticket, and
  # organization. The job is safe to rerun because target uniqueness is
  # database-enforced and collision suffixes derive only from the target ID.
  class BackfillCanonicalLinksJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 500
    TARGETS = {
      "event" => Events::Event,
      "ticket" => Ticketing::Ticket,
      "organization" => Organizations::Organization
    }.freeze

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

      TARGETS.each do |target_type, model|
        model.in_batches(of: normalized_batch_size(batch_size)) do |batch|
          canonical_ids = canonical_target_ids(target_type, batch)
          batch.each { |target| yield target_type, target, canonical_ids }
        end
      end
    end

    def backfill_target(target_type, target, canonical_ids:)
      return [ :preserved, 0 ] if canonical_ids.include?(target.id)

      candidates = slug_candidates(target_type, target)
      candidates.each_with_index do |slug, index|
        result = Links::Create.call(
          creator: nil,
          slug:, target_type:, target_id: target.id,
          canonical: true,
          system: true, target:
        )
        return [ :created, index ] if result.success?
        return [ :preserved, index ] if canonical_link_exists?(target_type, target.id, canonical_ids:)
        return [ :failed, index ] unless result.error.code == "slug_taken"
      end

      [ :failed, candidates.length ]
    end

    def canonical_link_exists?(target_type, target_id, canonical_ids:)
      return true if canonical_ids.include?(target_id)

      exists = Links::ShortLink.exists?(canonical: true, target_type:, target_id:)
      canonical_ids.add(target_id) if exists
      exists
    end

    def canonical_target_ids(target_type, batch)
      Links::ShortLink
        .where(canonical: true, target_type:)
        .where(target_id: batch.select(:id))
        .pluck(:target_id)
        .to_set
    end

    def slug_candidates(target_type, target)
      base = normalized_base_slug(target_type, target)
      candidates = [ base ] unless Links::ShortLink::RESERVED_SLUGS.include?(base)
      token = target.id.to_s.delete("-")
      candidates ||= []
      candidates << suffixed_slug(base, token.first(8))
      candidates << suffixed_slug(base, token.first(16))
      candidates.compact.uniq
    end

    def normalized_base_slug(target_type, target)
      base = if target_type == "ticket"
        "ticket-#{target.id}"
      else
        target.slug
      end

      normalized = base.to_s.downcase.strip.gsub(/[^a-z0-9_-]+/, "-")
      normalized = normalized.gsub(/\A[-_]+|[-_]+\z/, "")
      normalized.presence || "#{target_type}-#{target.id}"
    end

    def suffixed_slug(base, suffix)
      separator = "-"
      available = Links::ShortLink::MAX_SLUG_LENGTH - separator.length - suffix.length
      "#{base.first(available).sub(/[-_]\z/, "")}-#{suffix}"
    end

    def normalized_batch_size(value)
      value.to_i.clamp(1, BATCH_SIZE)
    end

    def empty_totals
      { created: 0, preserved: 0, collisions: 0, skipped: 0, failed: 0 }
    end
  end
end
