# frozen_string_literal: true

module Organizations
  class OwnerMembershipInvitationsController < Organizations::ApplicationController
    include Core::Pagination

    before_action :ensure_idempotency_key_present, only: %i[create resend revoke claim]
    before_action :set_organization, only: %i[index create]
    before_action :set_invitation, only: %i[resend revoke]
    before_action :set_no_store, only: %i[create resend claim preview]

    def index
      authorize MembershipInvitation.new(organization: @organization), :index?
      invitations = policy_scope(MembershipInvitation).where(organization_id: @organization.id)
        .order(created_at: :desc, id: :desc)
      total_count = invitations.count
      render_success(
        data: apply_pagination(invitations),
        serializer_options: { serializer: MembershipInvitationSerializer },
        pagination: pagination_metadata(total_count)
      )
    end

    def create
      attributes = invitation_params
      invitation = MembershipInvitation.new(organization: @organization, role: attributes[:role])
      authorize invitation, :create?
      result = MembershipInvitations::Create.call(
        organization: @organization,
        actor: current_user,
        phone: attributes[:phone],
        email: attributes[:email],
        role: attributes[:role],
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: invitation_response(result.value.record, result.value.token),
        status: :created,
        serializer_options: { invitation: { serializer: MembershipInvitationSerializer } }
      )
    end

    def resend
      authorize @invitation, :resend?
      result = MembershipInvitations::Resend.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: invitation_response(result.value.record, result.value.token),
        serializer_options: { invitation: { serializer: MembershipInvitationSerializer } }
      )
    end

    def revoke
      authorize @invitation, :revoke?
      result = MembershipInvitations::Revoke.call(
        invitation: @invitation,
        actor: current_user,
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: { invitation: result.value.record },
        serializer_options: { invitation: { serializer: MembershipInvitationSerializer } }
      )
    end

    def claim
      authorize MembershipInvitation.new, :claim?
      result = MembershipInvitations::Claim.call(
        token: params.require(:token),
        actor: current_user,
        idempotency_key:,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(
        data: { membership: result.value.membership, already_member: result.value.already_member? },
        serializer_options: { membership: { serializer: MembershipSerializer } }
      )
    end

    def preview
      authorize MembershipInvitation.new, :claim?
      result = MembershipInvitations::Preview.call(
        token: params.require(:token),
        actor: current_user,
        ip_address: request.remote_ip
      )
      return render_business_error(result.error) if result.failure?

      render_success(data: {
        organization: { id: result.value.organization_id, name: result.value.organization_name },
        role: result.value.role,
        inviter: { email: result.value.inviter_email },
        masked_contact: result.value.masked_contact,
        expires_at: result.value.expires_at
      })
    end

    private

    def set_organization
      @organization = Organizations::Organization.find(params[:owner_organization_id])
    end

    def set_invitation
      @organization = Organizations::Organization.find(params[:owner_organization_id])
      @invitation = MembershipInvitation.where(organization_id: @organization.id).find(params[:id])
    end

    def invitation_params
      params.require(:membership_invitation).permit(:phone, :email, :role)
    end

    def invitation_response(invitation, token)
      response = { invitation: }
      response[:claim_url] = Links::BrandedUrl.membership_invitation(invitation, token:) if token.present?
      response
    end

    def set_no_store
      response.headers["Cache-Control"] = "no-store, private"
    end
  end
end
