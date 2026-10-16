# frozen_string_literal: true

module Public
  class EventsController < ApplicationController
    def index
      at = Time.current
      search = Events::Public::Search.call(
        scope: Events::Event.publicly_visible, parameters: request.query_parameters, at:
      )
      return render_search_error(search.error) if search.failure?

      scope = search.value.scope
      featured = featured_result(at:, currency: search.value.currency) if featured_request?
      return featured_unavailable if featured&.failure?

      featured_snapshot = featured&.value
      scope = scope.where(id: featured_snapshot.event_ids) if featured_snapshot
      total_count = scope.count
      events = apply_pagination(scope.includes(public_event_includes)).to_a
      date_preview = Events::Public::DatesQuery.preview_for(
        events:, at:, limit: 1, statuses: Events::Public::DatesQuery::CARD_STATUSES
      )
      event_statuses = if featured_snapshot
        featured_snapshot.event_statuses
      else
        Catalog::Public::EventAvailabilitySummary.call(events:, at:, currency: search.value.currency)
      end

      render_success(
        I18n.t("event.success.index"),
        data: events,
        pagination: pagination_metadata(total_count),
        serializer_options: {
          serializer: featured_snapshot ? Marketing::FeaturedEventSerializer : Events::Public::EventListSerializer,
          event_statuses:,
          event_date_previews: date_preview.dates_by_event_id,
          recurring_event_ids: date_preview.recurring_event_ids.to_a,
          include: event_serializer_includes
        }
      )
    end

    def featured
      at = Time.current
      result = featured_result(at:)
      return featured_unavailable if result.failure?

      snapshot = result.value
      events = snapshot.placements.map(&:event)
      date_preview = Events::Public::DatesQuery.preview_for(
        events:, at:, limit: 1, statuses: Events::Public::DatesQuery::CARD_STATUSES
      )
      render_success(
        data: events,
        serializer_options: {
          serializer: Marketing::FeaturedEventSerializer,
          event_statuses: snapshot.event_statuses,
          event_date_previews: date_preview.dates_by_event_id,
          recurring_event_ids: date_preview.recurring_event_ids.to_a,
          include: event_serializer_includes
        }
      )
    end

    def show
      event = Events::Event.publicly_visible.includes(public_event_includes).find_by(slug: params[:slug])
      return render_error(I18n.t("errors.not_found", model: "event"), status: :not_found) unless event

      date_preview = Events::Public::DatesQuery.preview_for(events: [ event ], at: Time.current)
      render_success(
        I18n.t("event.success.show"),
        data: event,
        serializer_options: {
          serializer: Events::Public::EventDetailSerializer,
          event_date_previews: date_preview.dates_by_event_id,
          recurring_event_ids: date_preview.recurring_event_ids.to_a,
          include: event_serializer_includes
        }
      )
    end

    def dates
      event = Events::Event.publicly_visible.find_by(slug: params[:slug])
      return render_error(I18n.t("errors.not_found", model: "event"), status: :not_found) unless event

      result = Events::Public::DatesQuery.call(event:, parameters: request.query_parameters, at: Time.current)
      return render_search_error(result.error) if result.failure?

      scope = result.value.scope
      total_count = scope.count
      dates = apply_pagination(scope.includes(:venue).order(:starts_at, :id))
      render_success(
        I18n.t("event.success.show"), data: dates, pagination: pagination_metadata(total_count),
        serializer_options: { serializer: Events::Public::EventDateSerializer }
      )
    end

    private

    def featured_request? = params[:featured] == "true"

    def featured_result(at:, currency: nil) = Marketing::FeaturedPlacements::PublicQuery.call(at:, currency:)

    def render_search_error(error)
      render_error(error.message, status: error.status, code: error.code)
    end

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
        :recurrence_rule,
        { event_media: { file_attachment: :blob } },
        { event_organizations: :organization }
      ]
    end

    def event_serializer_includes
      [
        :categories, :event_media, :event_setting, :organization, :recurrence_rule,
        { event_organizations: :organization }
      ]
    end
  end
end
