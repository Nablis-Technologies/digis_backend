# frozen_string_literal: true

module Events
  class StaffRostersController < Events::ApplicationController
    def show
      event = Events::Event.find(params[:id])
      authorize event, policy_class: StaffRosterPolicy
      result = StaffInvitations::Roster.call(
        event:,
        assignments_page: params[:assignments_page],
        assignments_per_page: params[:assignments_per_page],
        invitations_page: params[:invitations_page],
        invitations_per_page: params[:invitations_per_page]
      )
      render_success(data: StaffRosterSerializer.call(result.value))
    end
  end
end
