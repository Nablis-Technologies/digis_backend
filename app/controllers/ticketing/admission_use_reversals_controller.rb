# frozen_string_literal: true

module Ticketing
  # Organizer-facing endpoint for append-only admission-use corrections.
  # The command owns locking, completeness, authorization, audit, and outbox
  # behavior; the controller only validates request shape and serializes it.
  class AdmissionUseReversalsController < Ticketing::ApplicationController
    include Core::CommandResponse

    skip_authorization only: :create
    before_action :ensure_idempotency_key_present
    before_action :load_checkin_log

    def create
      values = reversal_params
      result = Ticketing::AdmissionUseReversals::Create.call(
        checkin_log: @checkin_log,
        manager: current_user,
        reason_code: values.require(:reason_code),
        note: values[:note],
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        :"ticketing.scanner.success.admission_use_reversal_recorded",
        data: reversal_payload(result.value),
        status: :created
      )
    rescue ActionController::ParameterMissing
      render_error(
        I18n.t("ticketing.scanner.errors.admission_use_reversal_parameters_invalid"),
        status: :bad_request,
        code: "admission_use_reversal_parameters_invalid"
      )
    end

    private

    def load_checkin_log
      @checkin_log = Ticketing::CheckinLog.find_by(id: params[:id])
      return if @checkin_log

      render_error(
        I18n.t("ticketing.scanner.errors.admission_use_reversal_not_found"),
        status: :not_found,
        code: "admission_use_reversal_not_found"
      )
    end

    def reversal_params
      params.require(:admission_use_reversal).permit(:reason_code, :note)
    end

    def reversal_payload(value)
      {
        reversal_group_id: value.fetch(:reversal_group_id),
        checkin_log_id: value.fetch(:checkin_log_id),
        event_id: value.fetch(:event_id),
        reversal_version: value.fetch(:reversal_version),
        reversals: value.fetch(:reversals).map do |reversal|
          {
            id: reversal.id,
            admission_use_id: reversal.admission_use_id,
            reversed_by_id: reversal.reversed_by_id,
            reason_code: reversal.reason_code,
            note: reversal.note,
            reversed_at: reversal.reversed_at
          }
        end
      }
    end
  end
end
