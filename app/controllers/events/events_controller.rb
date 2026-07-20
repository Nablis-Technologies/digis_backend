# frozen_string_literal: true

module Events
  class EventsController < Events::ApplicationController
    include Core::Common

    self.model_class = Events::Event
    self.default_serializer = Events::EventSerializer

    # Draft CRUD index/show/update are plain nested CRUD handled by Core::Common.
    # Creation and publication go through explicit commands.

    def create
      organization = Organizations::Organization.find_by(id: event_params[:organization_id])
      return render_error(I18n.t("errors.not_found", model: "organization"),
                          status: :not_found) unless organization

      result = Events::Create.call(
        organization:,
        actor: current_user,
        attributes: event_params.except(:organization_id, :category_ids),
        category_ids: event_params[:category_ids]
      )
      render_service_result(result, success_status: :created,
                            serializer_options: { serializer: Events::EventSerializer })
    end

    def update
      set_object
      authorize @obj, :update?

      if @obj.update(model_params)
        if category_ids_present?
          result = Events::ReplaceCategories.call(
            event: @obj,
            category_ids: params[:event][:category_ids],
            actor: current_user
          )
          unless result.success?
            return render_service_result(result)
          end
        end
        render_success(data: @obj, serializer_options: { serializer: Events::EventSerializer })
      else
        render_error(errors: @obj.errors, status: :unprocessable_entity)
      end
    end

    def publish
      @obj = Events::Event.find_by!(id: params[:id])
      authorize @obj, :publish?
      result = Events::Publish.call(
        event: @obj,
        actor: current_user,
        idempotency_key: request_id
      )
      render_service_result(result, serializer_options: { serializer: Events::EventSerializer })
    end

    private

    def category_ids_present?
      params.dig(:event, :category_ids).present?
    end

    def event_params
      params.require(:event).permit(
        :title, :description, :slug, :status, :visibility,
        :timezone, :currency, :organization_id,
        category_ids: []
      )
    end

    def model_params
      event_params.except(:organization_id)
    end

    def request_id
      request.request_id || SecureRandom.uuid
    end
  end
end
