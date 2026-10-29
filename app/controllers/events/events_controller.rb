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
      @obj = @clazz.strict_loading.includes(organizer_eager_load + [ :event_setting ]).find(params[:id])
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
      return render_invalid_age_restriction_submission if invalid_age_restriction_submission?

      result = Events::Create.call(
        organization:,
        actor: current_user,
        attributes: event_params.except(:organization_id, :category_ids),
        category_ids: event_params[:category_ids],
        age_restriction_attributes: age_restriction_attributes
      )
      return render_service_result(result) if result.failure?

      render_success(
        I18n.t("event.success.create"),
        data: mutation_event(result.value.id),
        status: :created,
        serializer_options: { serializer: Events::Organizer::EventMutationSerializer }
      )
    end

    def update
      @obj = Events::Event.includes(:organization, :categories, :event_setting).find(params[:id])
      authorize @obj, :update?
      return render_invalid_age_restriction_submission if invalid_age_restriction_submission?

      age_attributes = age_restriction_attributes
      error = nil
      Events::Event.transaction do
        unless @obj.update(model_params)
          error = { errors: @obj.errors.to_hash, status: :unprocessable_entity }
          raise ActiveRecord::Rollback
        end

        error = update_age_restriction(age_attributes)
        raise ActiveRecord::Rollback if error

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
        render_success(
          data: mutation_event(@obj.id),
          serializer_options: { serializer: Events::Organizer::EventMutationSerializer }
        )
      end
    end

    def publish
      @obj = Events::Event.includes(:organization, :categories, :event_setting).find_by!(id: params[:id])
      authorize @obj, :publish?
      result = Events::Publish.call(
        event: @obj,
        actor: current_user,
        idempotency_key: idempotency_key
      )
      return render_service_result(result) if result.failure?

      render_success(
        I18n.t("event.success.publish"),
        data: mutation_event(result.value.id),
        serializer_options: { serializer: Events::Organizer::EventMutationSerializer }
      )
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

    def mutation_event(event_id)
      Events::Event.strict_loading.includes(:organization, :categories, :event_setting).find(event_id)
    end

    def age_restriction_attributes
      event_input = params[:event]
      return {} unless event_input.is_a?(ActionController::Parameters)
      return {} unless event_input.key?(:event_setting)

      setting_input = event_input[:event_setting]
      return { age_restriction: setting_input } unless setting_input.is_a?(ActionController::Parameters)
      return {} unless setting_input.key?(:config)

      config_input = setting_input[:config]
      return { age_restriction: config_input } unless config_input.is_a?(ActionController::Parameters)
      return {} unless config_input.key?(:age_restriction)

      value = config_input[:age_restriction]
      # Slice the known fields but preserve malformed supplied values so the
      # domain validator can return 422 instead of silently accepting omission.
      value = if value.is_a?(ActionController::Parameters)
        value.to_unsafe_h.slice(*Events::EventSetting::AGE_RESTRICTION_KEYS)
      elsif value.is_a?(Hash)
        value.deep_stringify_keys.slice(*Events::EventSetting::AGE_RESTRICTION_KEYS)
      else
        value
      end
      { age_restriction: value }
    end

    def invalid_age_restriction_submission?
      event_input = params[:event]
      return false unless event_input.is_a?(ActionController::Parameters)
      return true if event_input.key?(:age_restriction)
      return false unless event_input.key?(:event_setting)

      setting_input = event_input[:event_setting]
      return true unless setting_input.is_a?(ActionController::Parameters)
      return true if setting_input.key?(:age_restriction)
      return false unless setting_input.key?(:config)

      !setting_input[:config].is_a?(ActionController::Parameters)
    end

    def render_invalid_age_restriction_submission
      message = I18n.t("events.event_setting.errors.age_restriction.submission_shape")
      render_error(
        message,
        status: :unprocessable_entity,
        code: "invalid_age_restriction",
        errors: { "event_setting.config.age_restriction" => [ message ] }
      )
    end

    def update_age_restriction(attributes)
      return unless attributes.key?(:age_restriction)

      locked_event = Events::Event.lock.find(@obj.id)
      setting = Events::EventSetting.lock.find_by(event_id: locked_event.id) ||
        locked_event.build_event_setting(config: {})
      previous_value = setting.age_restriction
      setting.age_restriction = attributes.fetch(:age_restriction)
      return { errors: setting.errors.to_hash, status: :unprocessable_entity } unless setting.save

      current_value = setting.age_restriction
      record_age_restriction_change(locked_event, setting, previous_value, current_value) if previous_value != current_value
      nil
    end

    def record_age_restriction_change(event, setting, previous_value, current_value)
      event.record_audit!(
        "event.age_restriction.updated",
        audited_changes: { "age_restriction" => [ previous_value, current_value ] },
        metadata: { event_setting_id: setting.id },
        actor: current_user
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
