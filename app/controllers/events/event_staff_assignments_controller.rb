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

    before_action :set_assignment, only: %i[show suspend revoke activate change_role]
    before_action :ensure_idempotency_key_present, only: :revoke

    def suspend
      result = Events::StaffAssignments::Suspend.call(assignment: @assignment, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventStaffAssignmentSerializer })
    end

    def revoke
      result = Events::StaffAssignments::Revoke.call(
        assignment: @assignment, actor: current_user, idempotency_key:
      )
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

    def eager_load_config
      { default: [ :user, :organization ] }
    end
  end
end
