# frozen_string_literal: true

module Ticketing
  # Organizer API for safe access-code metadata and one-time creation output.
  class AccessCodesController < Ticketing::ApplicationController
    before_action :find_ticket_type
    before_action :find_access_code, only: %i[show destroy]
    before_action :ensure_idempotency_key_present, only: :create

    def index
      authorize Ticketing::AccessCode.new(ticket_type: @ticket_type), :index?
      codes = policy_scope(Ticketing::AccessCode).where(ticket_type_id: @ticket_type.id).order(:created_at)
      render_success(data: codes, serializer_options: { serializer: Ticketing::AccessCodeSerializer })
    end

    def show
      authorize @access_code
      render_success(data: @access_code, serializer_options: { serializer: Ticketing::AccessCodeSerializer })
    end

    def create
      authorize Ticketing::AccessCode.new(ticket_type: @ticket_type)
      result = Ticketing::AccessCodes::Create.call(
        ticket_type: @ticket_type,
        actor: current_user,
        attributes: access_code_params,
        idempotency_key:
      )

      if result.success?
        data = Ticketing::AccessCodeSerializer.new(result.value.record).attributes.merge(code: result.value.plaintext)
        render_success(data:, status: :created)
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize @access_code
      @access_code.destroy!
      render_success(status: :ok)
    end

    private

    def find_ticket_type
      manageable_events = Events::AuthorizationResolver.manageable_catalog_events(current_user)
      @ticket_type = Ticketing::TicketType
        .joins(:event_product)
        .where(catalog_event_products: { event_id: manageable_events.select(:id) })
        .find_by!(event_product_id: params[:event_product_id])
    end

    def find_access_code
      @access_code = policy_scope(Ticketing::AccessCode)
        .where(ticket_type_id: @ticket_type.id)
        .find(params[:id])
    end

    def access_code_params
      params.permit(:code, :label, :max_uses, :max_quantity_per_use, :starts_at, :expires_at, :active)
    end
  end
end
