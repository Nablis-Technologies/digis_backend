# frozen_string_literal: true

module Public
  class EventsController < ApplicationController
    def index
      at = Time.current
      featured = featured_result(at:) if featured_request?
      return featured_unavailable if featured&.failure?

      featured_snapshot = featured&.value
      scope = Events::Event.publicly_visible
      scope = scope.where(id: featured_snapshot.event_ids) if featured_snapshot
      total_count = scope.count
      events = apply_pagination(scope.order(published_at: :desc, id: :desc).includes(public_event_includes)).to_a
      event_statuses = featured_snapshot ? featured_snapshot.event_statuses : Catalog::Public::EventAvailabilitySummary.call(events:, at:)

      render_success(
        I18n.t("event.success.index"),
        data: events,
        pagination: pagination_metadata(total_count),
        serializer_options: {
          serializer: featured_snapshot ? Marketing::FeaturedEventSerializer : Events::Public::EventListSerializer,
          event_statuses:,
          include: event_serializer_includes
        }
      )
    end

    def featured
      result = featured_result(at: Time.current)
      return featured_unavailable if result.failure?

      snapshot = result.value
      render_success(
        data: snapshot.placements.map(&:event),
        serializer_options: {
          serializer: Marketing::FeaturedEventSerializer,
          event_statuses: snapshot.event_statuses,
          include: event_serializer_includes
        }
      )
    end

    def show
      event = Events::Event.publicly_visible.includes(public_event_includes).find_by(slug: params[:slug])
      return render_error(I18n.t("errors.not_found", model: "event"), status: :not_found) unless event

      render_success(
        I18n.t("event.success.show"),
        data: event,
        serializer_options: {
          serializer: Events::Public::EventDetailSerializer,
          include: event_serializer_includes
        }
      )
    end

    private

    def featured_request? = params[:featured] == "true"

    def featured_result(at:) = Marketing::FeaturedPlacements::PublicQuery.call(at:)

    def featured_unavailable
      render_error(
        I18n.t("event.errors.featured_events_unavailable"),
        status: :service_unavailable,
        code: "featured_events_unavailable"
      )
    end

    def public_event_includes
      [
        :categories, :event_setting, :organization,
        { event_dates: :venue },
        { event_media: { file_attachment: :blob } },
        { event_organizations: :organization }
      ]
    end

    def event_serializer_includes
      [
        :categories, :event_dates, :event_media, :event_setting, :organization,
        { event_dates: :venue }, { event_organizations: :organization }
      ]
    end
  end
end
