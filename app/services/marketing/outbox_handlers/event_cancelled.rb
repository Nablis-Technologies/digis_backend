# frozen_string_literal: true

module Marketing
  module OutboxHandlers
    # Event cancellation removes its placements from public discovery immediately
    # and creates one durable refund obligation for each paid unserved interval.
    class EventCancelled < Core::BaseService
      def initialize(event:)
        @event = event
      end

      def call
        event_id = @event.payload.fetch("event_id")
        placements = Marketing::FeaturedPlacement.where(event_id:, status: %w[pending_payment scheduled active])
          .order(:id).limit(500)
        placements.each do |placement|
          result = Marketing::FeaturedPlacements::Cancel.call(
            placement:, actor: nil, system: true, reason_code: "event_cancelled",
            idempotency_key: "event-cancellation-featured-placement-#{event_id}-#{placement.id}"
          )
          raise result.error if result.failure?
        end
        success(nil)
      rescue KeyError, ActiveRecord::RecordNotFound => exception
        failure(Core::BusinessError.new(exception.message, code: "event_cancellation_unavailable", status: :conflict))
      rescue Core::Error => exception
        failure(exception)
      end
    end
  end
end
