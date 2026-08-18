# frozen_string_literal: true

module Admin
  module Commercial
    # Admin assignment wizard boundary. It limits writes to draft creation and
    # delegates every financial transition to its idempotent domain command.
    class AssignmentsController < ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present,
        only: %i[create submit approve reject activate terminate]
      before_action :find_assignment, only: %i[show submit approve reject activate terminate]

      def index
        authorize ::Commercial::Assignment.new
        assignments = policy_scope(::Commercial::Assignment).includes(:organization, :event, :program)
        render_success(data: assignments)
      end

      def show
        authorize @assignment
        render_success(data: @assignment, serializer_options: { serializer: ::Commercial::AssignmentSerializer })
      end

      def create
        attributes = assignment_params
        organization = ::Organizations::Organization.find(attributes[:organization_id])
        version = ::Commercial::FeeScheduleVersion.find(attributes[:fee_schedule_version_id])
        event = attributes[:event_id].present? ? ::Events::Event.find(attributes[:event_id]) : nil
        program = attributes[:program_id].present? ? ::Commercial::Program.find(attributes[:program_id]) : nil
        assignment = ::Commercial::Assignment.new(organization:, fee_schedule_version: version,
          assignment_type: attributes[:assignment_type])
        authorize assignment
        result = ::Commercial::Admin::CreateAssignment.call(
          organization:, actor: current_user, fee_schedule_version: version,
          assignment_type: attributes[:assignment_type], reason: attributes[:reason],
          effective_from: attributes[:effective_from], effective_until: attributes[:effective_until],
          event:, program:, baseline_resolution_digest: attributes[:baseline_resolution_digest], idempotency_key:
        )
        render_service_result(result, success_status: :created,
          serializer_options: { serializer: ::Commercial::AssignmentSerializer })
      end

      def submit
        authorize @assignment, :submit?
        result = ::Commercial::Assignments::Submit.call(assignment: @assignment, actor: current_user, idempotency_key:)
        render_assignment_result(result)
      end

      def approve
        authorize @assignment, :approve?
        result = ::Commercial::Assignments::Approve.call(
          assignment: @assignment, actor: current_user, reason: transition_params[:reason],
          break_glass: transition_params[:break_glass], idempotency_key:
        )
        render_assignment_result(result)
      end

      def reject
        authorize @assignment, :reject?
        result = ::Commercial::Assignments::Reject.call(
          assignment: @assignment, actor: current_user, reason: transition_params[:reason], idempotency_key:
        )
        render_assignment_result(result)
      end

      def activate
        authorize @assignment, :activate?
        result = ::Commercial::Assignments::Activate.call(
          assignment: @assignment, actor: current_user, reason: transition_params[:reason],
          break_glass: transition_params[:break_glass], idempotency_key:
        )
        render_assignment_result(result)
      end

      def terminate
        authorize @assignment, :terminate?
        result = ::Commercial::Assignments::Terminate.call(
          assignment: @assignment, actor: current_user, reason: transition_params[:reason], idempotency_key:
        )
        render_assignment_result(result)
      end

      private

      def find_assignment
        @assignment = policy_scope(::Commercial::Assignment).includes(:organization, :event, :program).find(params[:id])
      end

      def assignment_params
        params.require(:assignment).permit(
          :organization_id, :event_id, :fee_schedule_version_id, :program_id,
          :assignment_type, :reason, :effective_from, :effective_until,
          :baseline_resolution_digest
        )
      end

      def transition_params
        permitted = params.permit(:reason, :break_glass)
        permitted[:break_glass] = ActiveModel::Type::Boolean.new.cast(permitted[:break_glass])
        permitted
      end

      def render_assignment_result(result)
        render_service_result(result, serializer_options: { serializer: ::Commercial::AssignmentSerializer })
      end
    end
  end
end
