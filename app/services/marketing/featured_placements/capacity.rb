# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # Reads and reserves per-surface inventory using half-open interval semantics.
    class Capacity < Core::BaseService
      Snapshot = Data.define(:available, :limit, :next_available_at, :reason)
      Reservation = Data.define(:event_id, :starts_at, :ends_at)

      def self.limit_for(surface:, at: Time.current)
        PlacementCapacityPolicy.active_for(surface:, at:)&.max_concurrent
      rescue PlacementCapacityPolicy::AmbiguousActivePoliciesError
        Rails.logger.error("[marketing.capacity_policy_ambiguous] surface=#{surface}")
        nil
      end

      def initialize(event_id:, surface:, starts_at:, ends_at:, at: Time.current)
        @event_id = event_id
        @surface = surface.to_s
        @starts_at = starts_at.to_time.utc
        @ends_at = ends_at.to_time.utc
        @at = at.to_time.utc
      end

      def call
        limit = configured_limit
        return failure(error(:capacity_unavailable, status: :service_unavailable)) unless limit

        reservations = reservations_for(starts_at, ends_at)
        available = interval_available?(reservations, event_id:, starts_at:, ends_at:, limit:)
        next_at = next_available_start(reservations, limit:) unless available
        success(Snapshot.new(available:, limit:, next_available_at: next_at, reason: available ? nil : :capacity_full))
      rescue ArgumentError, TypeError
        failure(error(:capacity_unavailable, status: :service_unavailable))
      end

      private

      attr_reader :event_id, :surface, :starts_at, :ends_at, :at

      def configured_limit
        self.class.limit_for(surface:, at:)
      end

      def reservations_for(window_start, window_end)
        pending_ids = Orders::BillingPurchase
          .where(source_type: "Marketing::FeaturedPlacement", status: "pending_payment")
          .where("expires_at > ?", at)
          .select(:source_id)
        scope = Marketing::FeaturedPlacement.where(surface:)
          .where("starts_at < ? AND ends_at > ?", window_end, window_start)
        rows = scope.where(status: %w[scheduled active])
          .or(scope.where(status: "pending_payment", id: pending_ids))
          .pluck(:event_id, :starts_at, :ends_at)
        rows.map { |row_event_id, row_start, row_end| Reservation.new(row_event_id, row_start, row_end) }
      end

      def interval_available?(reservations, event_id:, starts_at:, ends_at:, limit:)
        return false if reservations.any? do |reservation|
          reservation.event_id == event_id && overlaps?(reservation.starts_at, reservation.ends_at, starts_at, ends_at)
        end

        maximum_overlap(reservations, starts_at:, ends_at:) <= limit
      end

      def maximum_overlap(reservations, starts_at:, ends_at:)
        edges = [ [ starts_at, 1 ], [ ends_at, -1 ] ]
        reservations.each do |reservation|
          clipped_start = [ reservation.starts_at, starts_at ].max
          clipped_end = [ reservation.ends_at, ends_at ].min
          next unless clipped_start < clipped_end

          edges << [ clipped_start, 1 ]
          edges << [ clipped_end, -1 ]
        end
        current = 0
        maximum = 0
        edges.sort_by { |time, delta| [ time, delta ] }.each do |_time, delta|
          current += delta
          maximum = [ maximum, current ].max
        end
        maximum
      end

      def next_available_start(reservations, limit:)
        minimum_end = ends_at - PlacementOffer::MINIMUM_DURATION_SECONDS
        reservations.map(&:ends_at).select { |candidate| candidate >= starts_at && candidate <= minimum_end }
          .uniq.sort.find do |candidate|
            interval_available?(reservations, event_id:, starts_at: candidate, ends_at:, limit:)
          end
      end

      def overlaps?(left_start, left_end, right_start, right_end)
        left_start < right_end && left_end > right_start
      end

      def error(key, status: :conflict)
        Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.#{key}"), code: key.to_s, status:
        )
      end
    end
  end
end
