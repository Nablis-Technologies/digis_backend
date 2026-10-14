# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # The canonical bounded, payment-backed public Featured placement read model.
    class PublicQuery < Core::BaseService
      ROTATION_WINDOW_SECONDS = 1.hour.to_i
      MAX_FETCH_SIZE = PlacementCapacityPolicy::MAX_CONCURRENT

      Result = Data.define(:placements, :event_statuses) do
        def event_ids = placements.map(&:event_id).uniq
      end

      def initialize(at: Time.current)
        @at = at.to_time.utc
      end

      def call
        placements = serving_placements(limit: MAX_FETCH_SIZE + 2)
        return failure(featured_unavailable_error) if placements.length > MAX_FETCH_SIZE + 1

        events = placements.map(&:event).uniq(&:id)
        statuses = Catalog::Public::EventAvailabilitySummary.call(events:, at:)
        eligible = placements.select do |placement|
          statuses.dig(placement.event_id, :ticket_availability) == "available"
        end.uniq(&:event_id)
        return failure(featured_unavailable_error) if eligible.length > MAX_FETCH_SIZE

        rotated = rotate(eligible)
        success(Result.new(rotated, statuses.slice(*rotated.map(&:event_id))))
      end

      private

      attr_reader :at

      def featured_unavailable_error
        Rails.logger.error("[marketing.featured_events_unavailable] eligible_or_scan_bound_exceeded hard_limit=#{MAX_FETCH_SIZE}")
        Core::BusinessError.new(
          I18n.t("event.errors.featured_events_unavailable"),
          code: "featured_events_unavailable", status: :service_unavailable
        )
      end

      def serving_placements(limit:)
        Marketing::FeaturedPlacement.joins(:event)
          .joins(<<~SQL.squish)
            INNER JOIN orders_billing_purchases AS featured_purchases
              ON featured_purchases.source_type = 'Marketing::FeaturedPlacement'
             AND featured_purchases.source_id = marketing_featured_placements.id
            INNER JOIN orders_payments AS featured_payments
              ON featured_payments.billing_purchase_id = featured_purchases.id
          SQL
          .where(surface: "public_discovery", status: %w[scheduled active])
          .where("marketing_featured_placements.starts_at <= ? AND marketing_featured_placements.ends_at > ?", at, at)
          .where(featured_purchases: { status: "paid" })
          .where("featured_payments.status = 'succeeded' AND featured_payments.accepted_at IS NOT NULL")
          .where(events_events: { status: "published", visibility: "public" })
          .where(<<~SQL.squish, at)
            (SELECT MIN(featured_dates.starts_at)
               FROM events_event_dates AS featured_dates
              WHERE featured_dates.event_id = events_events.id
                AND featured_dates.status = 'scheduled') > ?
          SQL
          .includes(event: [
            :categories, :event_setting, :organization,
            { event_dates: :venue },
            { event_media: { file_attachment: :blob } },
            { event_organizations: :organization }
          ])
          .order(:starts_at, :id)
          .distinct
          .limit(limit)
          .to_a
      end

      def rotate(placements)
        return placements if placements.length < 2

        offset = (at.to_i / ROTATION_WINDOW_SECONDS) % placements.length
        placements.rotate(offset)
      end
    end
  end
end
