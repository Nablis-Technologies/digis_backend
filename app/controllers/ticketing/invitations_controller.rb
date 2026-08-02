# frozen_string_literal: true

module Ticketing
  # Organizer API for safe guest-list invitation metadata and token creation.
  class InvitationsController < Ticketing::ApplicationController
    before_action :find_ticket_type
    before_action :find_invitation, only: %i[show destroy]
    before_action :ensure_idempotency_key_present, only: :create

    def index
      authorize Ticketing::Invitation.new(ticket_type: @ticket_type), :index?
      invitations = policy_scope(Ticketing::Invitation).where(ticket_type_id: @ticket_type.id).order(:created_at)
      render_success(data: invitations, serializer_options: { serializer: Ticketing::InvitationSerializer })
    end

    def show
      authorize @invitation
      render_success(data: @invitation, serializer_options: { serializer: Ticketing::InvitationSerializer })
    end

    def create
      authorize Ticketing::Invitation.new(ticket_type: @ticket_type)
      result = Ticketing::Invitations::Create.call(
        ticket_type: @ticket_type,
        actor: current_user,
        attributes: invitation_params,
        idempotency_key:
      )

      if result.success?
        data = Ticketing::InvitationSerializer.new(result.value.record).attributes.merge(token: result.value.token)
        render_success(data:, status: :created)
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize @invitation
      @invitation.update!(status: "revoked") unless @invitation.status == "revoked"
      render_success(data: @invitation, serializer_options: { serializer: Ticketing::InvitationSerializer })
    end

    private

    def find_ticket_type
      manageable_events = Events::AuthorizationResolver.manageable_catalog_events(current_user)
      @ticket_type = Ticketing::TicketType
        .joins(:event_product)
        .where(catalog_event_products: { event_id: manageable_events.select(:id) })
        .find_by!(event_product_id: params[:event_product_id])
    end

    def find_invitation
      @invitation = policy_scope(Ticketing::Invitation)
        .where(ticket_type_id: @ticket_type.id)
        .find(params[:id])
    end

    def invitation_params
      params.permit(:name, :email, :phone, :allowed_quantity, :expires_at)
    end
  end
end
