module Organizations
  class OrganizationsController < ::Public::ApplicationController
  include Core::FollowableActions

    def index
      organizations = Organizations::Organization.all.with_attached_profile
      total_count = organizations.count if paginated_request?
      organizations = paginated_request? ? apply_pagination(organizations) : organizations.limit(25)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: organizations, serializer_options: { serializer: Organizations::Public::OrganizationListSerializer }, pagination: pagination)
    end

    def show
      organization = Organizations::Organization.with_attached_profile.find(params[:id])
      render_success(data: organization, serializer_options: { serializer: Organizations::Public::OrganizationDetailSerializer })
    end

    private

    def followable_class
      Organizations::Organization
    end
  end
end
