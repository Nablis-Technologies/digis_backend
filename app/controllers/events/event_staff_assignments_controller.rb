# frozen_string_literal: true

module Events
  class EventStaffAssignmentsController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::CommandResponse

    self.model_class = Events::EventStaffAssignment
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_staff_assignments
    self.default_serializer = Events::EventStaffAssignmentSerializer

    before_action :set_assignment, only: %i[show update destroy suspend revoke activate change_role]

    def create
      @parent = Events::Event.find(params[:event_id])
      result = Events::StaffAssignments::Assign.call(
        event: @parent, actor: current_user,
        user: Core::User.find(staff_params[:user_id]),
        organization: @parent.organization,
        role: staff_params[:role]
      )
      render_service_result(result,
        serializer_options: { serializer: Events::EventStaffAssignmentSerializer },
        success_status: :created)
    end

    def suspend
      result = Events::StaffAssignments::Suspend.call(assignment: @assignment, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    def revoke
      result = Events::StaffAssignments::Revoke.call(assignment: @assignment, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    def activate
      result = Events::StaffAssignments::Activate.call(assignment: @assignment, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    def change_role
      result = Events::StaffAssignments::ChangeRole.call(assignment: @assignment, actor: current_user, role: params[:role])
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    private

    def set_assignment
      @assignment = Events::Event.find(params[:event_id]).event_staff_assignments.find(params[:id])
    end

    def staff_params
      params.require(:event_staff_assignment).permit(:user_id, :role)
    end

    def model_params
      params.require(:event_staff_assignment).permit(:user_id, :organization_id)
    end

    def eager_load_config
      { default: [ :user, :organization ] }
    end
  end
end
