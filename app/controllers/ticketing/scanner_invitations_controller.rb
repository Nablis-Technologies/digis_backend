# frozen_string_literal: true

module Ticketing
  # Creates and manages phone-targeted event scanner delegations. Pairing
  # material is returned only on the authorized mutation response, never in a
  # serializer, audit record, or roster projection.
  class ScannerInvitationsController < Ticketing::ApplicationController
    include Core::CommandResponse
    include Core::IdempotencyKeyResolver

    before_action :set_invitation, only: %i[resend reset_pairing revoke]
    before_action :ensure_idempotency_key_present, only: %i[create resend reset_pairing revoke]

    skip_authorization only: :create

    def create
      event = Events::Event.find(params[:event_id])
      values = invitation_params
      result = Ticketing::Scanners::CreateInvitation.call(
        event:,
        actor: current_user,
        phone: values.fetch(:phone),
        label: values[:display_label],
        note: values[:note],
        zone_mode: values.fetch(:zone_mode, "all_current_zones"),
        zone_ids: values.fetch(:zone_ids, []),
        starts_at: values[:starts_at],
        ends_at: values[:ends_at],
        expires_at: values[:expires_at],
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_invitation_result(result, message: :"ticketing.scanner.success.invitation_created",
                                      status: result.value.replayed? ? :ok : :created,
                                      pairing_material: true)
    rescue ActionController::ParameterMissing, KeyError
      render_error(
        :"ticketing.scanner.errors.scanner_invitation_parameters_invalid",
        status: :bad_request,
        code: "scanner_invitation_parameters_invalid"
      )
    rescue ActiveRecord::RecordNotFound
      render_error(
        :"ticketing.scanner.errors.event_not_found",
        status: :not_found,
        code: "event_not_found"
      )
    end

    def resend
      authorize @invitation, :resend?, policy_class: Ticketing::ScannerInvitationPolicy
      result = Ticketing::Scanners::ResendInvitation.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_invitation_result(result, message: :"ticketing.scanner.success.invitation_resent",
                                      status: :ok, pairing_material: true)
    end

    def reset_pairing
      authorize @invitation, :reset_pairing?, policy_class: Ticketing::ScannerInvitationPolicy
      result = Ticketing::Scanners::ResetPairing.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_invitation_result(result, message: :"ticketing.scanner.success.pairing_reset",
                                      status: :ok, pairing_material: true)
    end

    def revoke
      authorize @invitation, :revoke?, policy_class: Ticketing::ScannerInvitationPolicy
      result = Ticketing::Scanners::RevokeInvitation.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:
      )
      return render_business_error(result.error) if result.failure?

      render_invitation_result(result, message: :"ticketing.scanner.success.invitation_revoked",
                                      status: :ok, pairing_material: false)
    end

    private

    def set_invitation
      @invitation = policy_scope(
        Ticketing::ScannerInvitation,
        policy_scope_class: Ticketing::ScannerInvitationPolicy::Scope
      ).find(params[:id])
    end

    def invitation_params
      params.require(:scanner_invitation).permit(
        :phone,
        :display_label,
        :note,
        :zone_mode,
        :starts_at,
        :ends_at,
        :expires_at,
        zone_ids: []
      ).to_h.symbolize_keys
    end

    def safe_invitation_payload(invitation)
      {
        id: invitation.id,
        event_id: invitation.event_id,
        masked_phone: invitation.masked_phone,
        display_label: invitation.display_label,
        note: invitation.organizer_note,
        status: invitation.status,
        delivery_status: invitation.delivery_status,
        delivery_revision: invitation.delivery_revision,
        zone_mode: invitation.zone_mode,
        zone_ids: invitation.selected_zone_ids,
        starts_at: invitation.starts_at,
        ends_at: invitation.ends_at,
        expires_at: invitation.expires_at
      }
    end

    def render_invitation_result(result, message:, status:, pairing_material:)
      invitation = result.value.record
      response.headers["Cache-Control"] = "no-store, private"
      data = {
        scanner_invitation: safe_invitation_payload(invitation),
        replayed: result.value.replayed?
      }
      if pairing_material
        data[:pairing_material] = if result.value.token.present? && result.value.pairing_code.present?
          {
            token: result.value.token,
            pairing_code: result.value.pairing_code,
            pairing_url: Links::BrandedUrl.scanner_pairing(invitation, token: result.value.token),
            pairing_code_expires_at: invitation.pairing_code_expires_at
          }
        end
      end
      render_success(message, data:, status:)
    end
  end
end
