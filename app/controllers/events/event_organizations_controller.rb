# frozen_string_literal: true

module Events
  class EventOrganizationsController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::CommandResponse

    self.model_class = Events::EventOrganization
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_organizations
    self.default_serializer = Events::EventOrganizationSerializer

    before_action :set_organization, only: %i[revoke activate]

    def index
      authorize @parent.event_organizations.new, :index? unless skip_authorization_for_action?

      collaborators = policy_scope(@parent.event_organizations)
        .includes(:organization)
      collaborators = filter_records(collaborators)
      collaborators = collaborator_order(collaborators)
      total_count = collaborators.count if paginated_request?
      collaborators = paginated_request? ? apply_pagination(collaborators) : collaborators.limit(default_per_page)
      render_success(
        data: {
          primary_organization: organization_summary(@parent.organization),
          collaborators: collaborators.map do |collaborator|
            Events::EventOrganizationSerializer.new(collaborator).attributes
          end
        },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    def revoke
      result = Events::OrganizationTransitions::Revoke.call(organization: @organization, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventOrganizationSerializer })
    end

    def activate
      result = Events::OrganizationTransitions::Activate.call(organization: @organization, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventOrganizationSerializer })
    end

    private

    def set_organization
      @organization = Events::Event.find(params[:event_id]).event_organizations.find(params[:id])
    end

    def organization_summary(organization)
      return unless organization

      Events::Public::OrganizationSummarySerializer.new(organization).attributes
    end

    def model_params
      params.require(:event_organization).permit(:organization_id, :type, :role)
    end

    def eager_load_config
      { default: [ :organization ] }
    end

    def collaborator_order(collaborators)
      return apply_ordering(collaborators.reorder(nil)) if params[:order_by].present?

      collaborators.order(created_at: :desc, id: :desc)
    end

    def allowed_order_columns
      %w[id type role status created_at updated_at]
    end
  end
end
