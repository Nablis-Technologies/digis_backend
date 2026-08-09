# frozen_string_literal: true

module Ticketing
  # Organizer endpoint for one immutable, audited registration exception.
  class PurchaseLimitOverridesController < Ticketing::ApplicationController
    before_action :ensure_idempotency_key_present
    before_action :load_registration

    def create
      authorize @registration, :create?, policy_class: Ticketing::PurchaseLimitOverridePolicy
      result = Ticketing::PurchaseLimits::GrantOverride.call(
        registration: @registration,
        approved_by: current_user,
        additional_packages: params.require(:additional_packages),
        reason_code: params.require(:reason_code),
        idempotency_key:
      )
      return render_service_result(result, success_status: :created) if result.failure?

      render_success(data: serialized_override(result.value), status: :created)
    end

    private

    def load_registration
      @registration = Ticketing::Registration.includes(:event, :ticket_type, :user).find(params[:registration_id])
    end

    def serialized_override(override)
      override.attributes.slice(
        "id", "registration_id", "ticket_type_id", "user_id", "scope_event_date_id",
        "additional_packages", "approved_by_id", "reason_code", "created_at", "updated_at"
      )
    end
  end
end
