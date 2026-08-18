# frozen_string_literal: true

module Ticketing
  # Owner invitation and recipient acceptance endpoints for delegated slots.
  # Token plaintext is accepted from the request body and is never serialized
  # as part of the persisted claim record.
  class CredentialClaimsController < Ticketing::ApplicationController
    include Core::CommandResponse

    skip_authorization only: :accept

    before_action :ensure_idempotency_key_present, only: :create
    before_action :load_ticket, only: :create

    def create
      authorize @ticket, :delegate?, policy_class: Ticketing::TicketPolicy
      credential = @ticket.credentials.find(params.require(:credential_id))
      result = Ticketing::CredentialClaims::Invite.call(
        credential:,
        actor: current_user,
        phone: params.require(:phone),
        expires_at: params[:expires_at],
        idempotency_key:
      )
      return render_service_result(result, success_status: :created) if result.failure?

      render_success(
        data: { claim: result.value.claim, token: result.value.token },
        status: :created,
        serializer_options: {
          claim: { serializer: Ticketing::CredentialClaimSerializer }
        }
      )
    end

    def accept
      claim = Ticketing::CredentialClaim.find(params.require(:id))
      token = params.require(:token)
      return render_invalid_claim unless claim.token_digest == Ticketing::CredentialClaim.token_digest_for(token:)

      result = Ticketing::CredentialClaims::Accept.call(
        token:,
        actor: current_user
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: { claim: result.value.claim, credential: result.value.credential },
        serializer_options: {
          claim: { serializer: Ticketing::CredentialClaimSerializer },
          credential: { serializer: Ticketing::CredentialSerializer }
        }
      )
    end

    private

    def load_ticket
      @ticket = Ticketing::Ticket.find(params[:ticket_id])
    end

    def render_invalid_claim
      render_error(
        :"ticketing.package_workflow.errors.claim_invalid",
        status: :not_found,
        code: "claim_invalid"
      )
    end
  end
end
