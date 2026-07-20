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

    def create
      organization = Organizations::Organization.find_by(id: event_params[:organization_id])
      return render_error(I18n.t("errors.not_found", model: "organization"),
                          status: :not_found) unless organization

      object = @clazz.new(event_params.except(:organization_id, :category_ids))
      object.organization = organization
      object.created_by = current_user
      authorize object

      if object.save
        attach_categories(object) if event_params[:category_ids].present?
        render_success(data: object, serializer_options: { serializer: Events::EventSerializer }, status: :created)
      else
        render_error(errors: object.errors, status: :unprocessable_entity)
      end
    end

    def update
      set_object
      authorize @obj, :update?

      if @obj.update(model_params)
        attach_categories(@obj) if event_params[:category_ids].present?
        render_success(data: @obj, serializer_options: { serializer: Events::EventSerializer })
      else
        render_error(errors: @obj.errors, status: :unprocessable_entity)
      end
    end

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
      render_success(data: @obj, serializer_options: { serializer: Events::EventSerializer })
    end

    private

    def event_params
      params.require(:event).permit(
        :title, :description, :slug, :status, :visibility, :timezone, :currency,
        :organization_id, category_ids: []
      )
    end

    def model_params
      event_params.except(:organization_id, :category_ids)
    end

    def attach_categories(event)
      Events::ReplaceCategories.call(
        event:,
        category_ids: event_params[:category_ids],
        actor: current_user
      )
    end

    def request_id
      request.request_id || SecureRandom.uuid
    end
  end
end
