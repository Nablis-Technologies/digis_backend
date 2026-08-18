# frozen_string_literal: true

module Ticketing
  # Organizer-facing endpoint for the online manager correction of an
  # identity-mismatch attempt. Authorization and revalidation stay in the
  # command so non-HTTP callers receive the same safety guarantees.
  class CheckinIdentityOverridesController < Ticketing::ApplicationController
    include Core::CommandResponse

    skip_authorization only: :create
    before_action :ensure_idempotency_key_present
    before_action :load_checkin_log

    def create
      result = Ticketing::Checkins::OverrideIdentityMismatch.call(
        checkin_log: @checkin_log,
        manager: current_user,
        reason_code: identity_override_params.require(:reason_code),
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        :"ticketing.scanner.success.identity_override_recorded",
        data: checkin_payload(result.value),
        status: :created
      )
    rescue ActionController::ParameterMissing
      render_error(
        I18n.t("ticketing.scanner.errors.identity_override_parameters_invalid"),
        status: :bad_request,
        code: "identity_override_parameters_invalid"
      )
    end

    private

    def load_checkin_log
      @checkin_log = Ticketing::CheckinLog.find_by(id: params[:id])
      return if @checkin_log

      render_error(
        I18n.t("ticketing.scanner.errors.identity_override_not_found"),
        status: :not_found,
        code: "identity_override_not_found"
      )
    end

    def identity_override_params
      params.require(:identity_override).permit(:reason_code)
    end

    def checkin_payload(checkin)
      {
        id: checkin.id,
        result: checkin.result,
        overrides_checkin_log_id: checkin.overrides_checkin_log_id,
        identity_override_by_id: checkin.identity_override_by_id,
        identity_override_reason: checkin.identity_override_reason,
        identity_overridden_at: checkin.identity_overridden_at,
        admission_uses: checkin.admission_uses.order(:admission_slot_id, :usage_number).map do |use|
          { id: use.id, admission_slot_id: use.admission_slot_id, usage_number: use.usage_number }
        end
      }
    end
  end
end
