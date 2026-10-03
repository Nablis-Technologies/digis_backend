# frozen_string_literal: true

module Events
  class PublicEventsController < Events::ApplicationController
    include Core::Pagination

    class_attribute :default_serializer, default: nil

    skip_before_action :authenticate_user
    skip_authorization only: %i[index public_show]

    self.default_serializer = Events::Public::EventDetailSerializer

    def index
      scope = Events::Event.publicly_visible
      total_count = scope.count
      events = apply_pagination(scope.order(published_at: :desc, id: :desc)
        .includes(
          :categories, :event_setting, :organization,
          { event_dates: :venue },
          { event_media: { file_attachment: :blob } },
          { event_organizations: :organization }
        )).to_a
      at = Time.current
      event_statuses = Catalog::Public::EventAvailabilitySummary.call(events:, at:)

      render_success(I18n.t("event.success.index"),
                     data: events,
                     pagination: pagination_metadata(total_count),
                     serializer_options: {
                       serializer: Events::Public::EventListSerializer,
                       event_statuses:,
                       include: [ :categories, :event_dates, :event_media, :event_setting, :organization,
                                  { event_dates: :venue }, { event_organizations: :organization } ]
                     })
    end

    def public_show
      event = Events::Event.publicly_visible
                            .includes(
                              :categories, :event_setting, :organization,
                              { event_dates: :venue },
                              { event_organizations: :organization },
                              event_media: { file_attachment: :blob }
                            )
                            .find_by(slug: params[:slug])
      return render_error(I18n.t("errors.not_found", model: "event"),
                          status: :not_found) unless event

      render_success(I18n.t("event.success.show"),
                     data: event,
                     serializer_options: {
                       serializer: Events::Public::EventDetailSerializer,
                       include: [ :categories, :event_dates, :event_media, :event_setting, :organization,
                                  { event_dates: :venue }, { event_organizations: :organization } ]
                     })
    end
  end
end
