# frozen_string_literal: true

module Ticketing
  # Organizer CRUD surface for event-scoped form definitions. Version authoring
  # remains under the nested version endpoint so published schemas are managed
  # separately from form applicability.
  class RegistrationFormsController < Ticketing::ApplicationController
    include Core::Common

    self.model_class = Ticketing::RegistrationForm
    self.default_serializer = Ticketing::RegistrationFormSerializer

    prepend_before_action :find_event

    def index
      authorize @clazz.new(event: @event), :index?
      super
    end

    private

    def find_event
      @event = Events::Event.find(params[:event_id])
    end

    def set_object
      @obj = @clazz
        .where(event_id: @event.id)
        .includes(eager_loaded_associations)
        .find(params[:id])
    end

    def policy_sample
      @clazz.new(event: @event)
    end

    def skip_authorization_for_action?
      return true if action_name == "index"

      super
    end

    def apply_index_scope(scope)
      scope.where(event_id: @event.id)
    end

    def model_params
      params.permit(:name, :ticket_type_id, :active).merge(event_id: @event.id)
    end

    def eager_load_config
      { default: [ :versions ] }
    end

    def allowed_order_columns
      %w[id name active created_at updated_at]
    end

    def serializer_profile
      {
        index: { fields: Ticketing::RegistrationFormPolicy::FIELDS, include: [] },
        show: { fields: Ticketing::RegistrationFormPolicy::FIELDS, include: [ :versions ] },
        create: { fields: Ticketing::RegistrationFormPolicy::FIELDS, include: [ :versions ] },
        update: { fields: Ticketing::RegistrationFormPolicy::FIELDS, include: [ :versions ] }
      }
    end
  end
end
