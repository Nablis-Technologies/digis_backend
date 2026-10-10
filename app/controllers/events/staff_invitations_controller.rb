# frozen_string_literal: true

module Events
  class StaffInvitationsController < Events::ApplicationController
    include Core::Pagination

    before_action :ensure_idempotency_key_present, only: %i[create resend revoke claim]
    before_action :set_event, only: %i[index create]
    before_action :set_invitation, only: %i[resend revoke]
    before_action :set_no_store, only: %i[create resend claim preview]

    def index
      authorize StaffInvitation.new(event: @event), :index?
      invitations = policy_scope(StaffInvitation).where(event_id: @event.id).order(created_at: :desc, id: :desc)
      total_count = invitations.count
      render_success(
        data: apply_pagination(invitations),
        serializer_options: { serializer: StaffInvitationSerializer },
        pagination: pagination_metadata(total_count)
      )
    end

    def create
      attributes = invitation_params
      invitation = StaffInvitation.new(event: @event, role: attributes[:role])
      authorize invitation, :create?
      result = StaffInvitations::Create.call(
        event: @event,
        actor: current_user,
        phone: attributes[:phone],
        email: attributes[:email],
        role: attributes[:role],
        assignment_expires_at: attributes[:assignment_expires_at],
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: invitation_response(result.value.record, result.value.token),
        status: :created,
        serializer_options: { invitation: { serializer: StaffInvitationSerializer } }
      )
    end

    def resend
      authorize @invitation, :resend?
      result = StaffInvitations::Resend.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: invitation_response(result.value.record, result.value.token),
        serializer_options: { invitation: { serializer: StaffInvitationSerializer } }
      )
    end

    def revoke
      authorize @invitation, :revoke?
      result = StaffInvitations::Revoke.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: { invitation: result.value.record },
        serializer_options: { invitation: { serializer: StaffInvitationSerializer } }
      )
    end

    def claim
      authorize StaffInvitation.new, :claim?
      result = StaffInvitations::Claim.call(
        token: params.require(:token),
        actor: current_user,
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: { assignment: result.value.assignment, already_assigned: result.value.already_assigned? },
        serializer_options: { assignment: { serializer: EventStaffAssignmentSerializer } }
      )
    end

    def preview
      authorize StaffInvitation.new, :claim?
      result = StaffInvitations::Preview.call(
        token: params.require(:token),
        actor: current_user,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(data: {
        event: { id: result.value.event_id, title: result.value.event_title },
        role: result.value.role,
        inviter: { email: result.value.inviter_email },
        masked_contact: result.value.masked_contact,
        expires_at: result.value.expires_at,
        assignment_expires_at: result.value.assignment_expires_at
      })
    end

    private

    def set_event
      @event = Events::Event.find(params[:event_id])
    end

    def set_invitation
      @event = Events::Event.find(params[:event_id])
      @invitation = StaffInvitation.where(event_id: @event.id).find(params[:id])
    end

    def invitation_params
      params.require(:staff_invitation).permit(:phone, :email, :role, :assignment_expires_at)
    end

    def invitation_response(invitation, token)
      response = { invitation: }
      response[:claim_url] = Links::BrandedUrl.staff_invitation(invitation, token:) if token.present?
      response
    end

    def set_no_store
      response.headers["Cache-Control"] = "no-store, private"
    end
  end
end
