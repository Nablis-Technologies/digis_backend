# frozen_string_literal: true

module Ticketing
  # Changes a paired scanner's event/zone/time scope through the authoritative
  # Ticketing command; offline clients receive the new zones on their next delta.
  class ScannerDeviceAssignmentsController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :set_assignment
    before_action :ensure_idempotency_key_present, only: :update

    def update
      authorize @assignment, :update?, policy_class: Ticketing::ScannerDeviceAssignmentPolicy
      values = assignment_params
      result = Ticketing::Scanners::UpdateAssignment.call(
        assignment: @assignment,
        actor: current_user,
        zone_mode: values.fetch(:zone_mode),
        zone_ids: values.fetch(:zone_ids, []),
        starts_at: values[:starts_at],
        ends_at: values[:ends_at],
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        :"ticketing.scanner.success.assignment_updated",
        status: :ok,
        data: assignment_payload(result.value.assignment)
      )
    rescue ActionController::ParameterMissing, KeyError
      render_error(
        :"ticketing.scanner.errors.assignment_parameters_invalid",
        status: :bad_request,
        code: "assignment_parameters_invalid"
      )
    end

    private

    def set_assignment
      @assignment = Ticketing::ScannerDeviceAssignment.includes(:event)
        .find_by!(id: params[:id], event_id: params[:event_id])
    end

    def assignment_params
      params.require(:scanner_device_assignment).permit(
        :zone_mode,
        :starts_at,
        :ends_at,
        zone_ids: []
      ).to_h.symbolize_keys
    end

    def assignment_payload(assignment)
      {
        id: assignment.id,
        event_id: assignment.event_id,
        event_staff_assignment_id: assignment.event_staff_assignment_id,
        scanner_device_id: assignment.scanner_device_id,
        status: assignment.status,
        starts_at: assignment.starts_at,
        ends_at: assignment.ends_at,
        zones: assignment.assignment_zones.includes(:access_zone).map do |mapping|
          { id: mapping.access_zone_id, name: mapping.access_zone.name, code: mapping.access_zone.code }
        end
      }
    end
  end
end
