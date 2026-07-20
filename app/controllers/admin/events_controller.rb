# frozen_string_literal: true

module Admin
  # Platform-administration surface for events. Mirrors Admin::OrganizationsController:
  # full CRUD over every event plus moderation actions (force publish/unpublish).
  # Schedules, media, staff, and consent-document administration are later tasks.
  class EventsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Event
    self.default_serializer = Events::EventSerializer

    auditable on: %i[create update destroy publish unpublish]

    def publish
      set_object
      authorize @obj, :publish?
      result = Events::Publish.call(event: @obj, actor: current_user, idempotency_key: request_id)
      render_service_result(result, serializer_options: { serializer: Events::EventSerializer })
    end

    def unpublish
      set_object
      authorize @obj, :update?
      @obj.update!(status: "draft", published_at: nil)
      render_success(data: @obj, serializer: Events::EventSerializer)
    end

    private

    def model_params
      params.require(:event).permit(
        :title, :description, :slug, :status, :visibility, :timezone, :currency
      )
    end

    def request_id
      request.request_id || SecureRandom.uuid
    end
  end
end
