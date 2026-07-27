# frozen_string_literal: true

module Events
  class PublicEventsController < Events::ApplicationController
    class_attribute :default_serializer, default: nil

    skip_before_action :authenticate_user
    skip_authorization only: %i[index show]

    self.default_serializer = Events::Public::EventDetailSerializer

    def index
      events = Events::Event.publicly_visible
                              .includes(:categories)
                              .order(published_at: :desc)
      render_success(I18n.t("event.success.index"),
                     data: events,
                     serializer_options: { serializer: Events::Public::EventListSerializer })
    end

    def show
      event = Events::Event.publicly_visible.find_by(slug: params[:slug])
      return render_error(I18n.t("errors.not_found", model: "event"),
                          status: :not_found) unless event

      render_success(I18n.t("event.success.show"),
                     data: event,
                     serializer_options: { serializer: Events::Public::EventDetailSerializer })
    end
  end
end
