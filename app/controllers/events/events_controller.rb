# frozen_string_literal: true

module Events
  class EventsController < Events::ApplicationController
    include Core::Common

    self.model_class = Events::Event
    self.default_serializer = Events::EventSerializer

    before_action :ensure_idempotency_key_present, only: [ :publish ]

    # Draft CRUD index/show/update are plain nested CRUD handled by Core::Common.
    # Creation and publication go through explicit commands.

    def index
      @clazz = Events::Event
      authorize @clazz.new, :index?
      scoped_events = policy_scope(@clazz)
      organizer_events = Events::EventPolicy::Scope.new(current_user, @clazz).resolve_organizer_index
      events = scoped_events.where(id: organizer_events.select(:id)).includes(organizer_eager_load)
      events = filter_records(events)
      events = organizer_event_order(events)
      total_count = events.count if paginated_request?
      events = paginated_request? ? apply_pagination(events) : events.limit(default_per_page)
      render_success(
        data: events,
        serializer_options: {
          serializer: Events::Organizer::EventSerializer,
          projection: :index
        },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    def show
      @obj = @clazz.includes(organizer_eager_load).find(params[:id])
      authorize @obj
      render_success(
        data: @obj,
        serializer_options: {
          serializer: Events::Organizer::EventSerializer,
          projection: :show
        }
      )
    end

    def create
      organization = Organizations::Organization.find_by(id: event_params[:organization_id])
      return render_error(I18n.t("errors.not_found", model: "organization"),
                          status: :not_found) unless organization

      event = Events::Event.new(organization: organization)
      authorize event, :create?

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

      error = nil
      Events::Event.transaction do
        unless @obj.update(model_params)
          error = { errors: @obj.errors.to_hash, status: :unprocessable_entity }
          raise ActiveRecord::Rollback
        end

        if category_ids_present?
          result = Events::ReplaceCategories.call(
            event: @obj,
            category_ids: params[:event][:category_ids],
            actor: current_user
          )
          unless result.success?
            error = { errors: result.error.errors.to_hash, status: result.error.status }
            raise ActiveRecord::Rollback
          end
        end
      end

      if error
        render_error(errors: error[:errors], status: error[:status])
      else
        render_success(data: @obj.reload, serializer_options: { serializer: Events::EventSerializer })
      end
    end

    def publish
      @obj = Events::Event.find_by!(id: params[:id])
      authorize @obj, :publish?
      result = Events::Publish.call(
        event: @obj,
        actor: current_user,
        idempotency_key: idempotency_key
      )
      render_service_result(result, serializer_options: { serializer: Events::EventSerializer })
    end

    private

    def category_ids_present?
      params.dig(:event, :category_ids).present?
    end

    def event_params
      params.require(:event).permit(
        :title, :description, :slug, :visibility,
        :timezone, :currency, :organization_id,
        category_ids: []
      )
    end

    def model_params
      event_params.except(:organization_id)
    end

    def organizer_eager_load
      [
        :organization,
        :categories,
        { event_dates: :venue },
        { event_media: { file_attachment: :blob } }
      ]
    end

    # Core::Common allowlists only id/created_at/updated_at, so an organizer list
    # sorted by "Event" or "Status" fell through Core::Pagination#order_by to
    # `id` and appeared to ignore the click. These are the columns the organizer
    # events table actually offers, and all three are plain columns on
    # events_events - no joins, no computed values.
    def allowed_order_columns
      %w[id title status published_at created_at updated_at]
    end

    def organizer_event_order(events)
      return apply_ordering(events) if params[:order_by].present?

      events.order(published_at: :desc, id: :desc)
    end
  end
end
