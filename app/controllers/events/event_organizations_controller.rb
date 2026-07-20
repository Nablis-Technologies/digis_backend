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

      data, serializer_options = resolve_block_result(default: policy_scope(@parent.event_organizations))
      data = apply_index_scope(data)
      data = data.includes(eager_loaded_associations) if data.respond_to?(:includes)
      data = filter_records(data)
      data = apply_ordering(data)
      total_count = data.count if paginated_request?
      data = apply_pagination(data) if paginated_request?

      data = Array(data)
      data << primary_owner_entry if primary_owner_entry

      serializer_options[:include] ||= renderable_associations
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: data, serializer_options: serializer_options, pagination: pagination)
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

    def primary_owner_entry
      return nil unless @parent.organization_id

      Events::EventOrganization.new(
        event_id: @parent.id,
        organization_id: @parent.organization_id,
        type: "owner",
        role: "primary_owner",
        status: "active"
      )
    end

    def model_params
      params.require(:event_organization).permit(:organization_id, :type, :role)
    end
  end
end
