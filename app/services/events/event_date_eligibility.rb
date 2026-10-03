# frozen_string_literal: true

require "set"

module Events
  # Shared date-sellability projection used by checkout and catalog reads.
  class EventDateEligibility
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

    Snapshot = Data.define(:dates_by_id, :eligible_date_ids, :has_dates) do
      def initialize(event_dates:, at:, has_dates: nil)
        dates = Array(event_dates)
        eligible_ids = dates.filter_map do |date|
          date.id.to_s if date.status == "scheduled" && date.starts_at > at
        end.to_set
        super(
          dates_by_id: dates.index_by { |date| date.id.to_s },
          eligible_date_ids: eligible_ids,
          has_dates: has_dates.nil? ? dates.any? : has_dates
        )
      end

      def eligible?(event_date_ids)
        ids = Array(event_date_ids).map(&:to_s).uniq
        return false unless ids.all? { |id| id.match?(UUID_PATTERN) }
        return !has_dates || eligible_date_ids.any? if ids.empty?

        ids.all? { |id| dates_by_id.key?(id) && eligible_date_ids.include?(id) }
      end
    end

    def self.snapshot(event_dates:, at:, has_dates: nil)
      Snapshot.new(event_dates:, at:, has_dates:)
    end

    def self.valid_ids?(ids)
      Array(ids).map(&:to_s).all? { |id| id.match?(UUID_PATTERN) }
    end
  end
end
