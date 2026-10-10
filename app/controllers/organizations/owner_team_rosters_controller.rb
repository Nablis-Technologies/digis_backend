# frozen_string_literal: true

module Organizations
  class OwnerTeamRostersController < Organizations::ApplicationController
    def show
      organization = Organizations::Organization.find(params[:id])
      authorize organization, policy_class: OwnerTeamRosterPolicy
      result = MembershipInvitations::Roster.call(
        organization:,
        memberships_page: params[:memberships_page],
        memberships_per_page: params[:memberships_per_page],
        invitations_page: params[:invitations_page],
        invitations_per_page: params[:invitations_per_page]
      )
      render_success(data: OwnerTeamRosterSerializer.call(result.value))
    end
  end
end
