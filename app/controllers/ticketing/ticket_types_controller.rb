# frozen_string_literal: true

module Ticketing
  # Organizer API for the ticket-only policy attached to one event product.
  class TicketTypesController < Ticketing::ApplicationController
    before_action :find_product
    before_action :find_ticket_type, only: %i[show update destroy]

    def show
      authorize @ticket_type
      render_success(data: @ticket_type)
    end

    def create
      return render_error("ticket type already exists", status: :unprocessable_entity) if @product.ticket_type.present?

      @ticket_type = @product.build_ticket_type(ticket_type_params)
      authorize @ticket_type
      if @ticket_type.save
        render_success(data: @ticket_type, status: :created)
      else
        render_error(errors: @ticket_type.errors, status: :unprocessable_entity)
      end
    end

    def update
      authorize @ticket_type
      if @ticket_type.update(ticket_type_params)
        render_success(data: @ticket_type)
      else
        render_error(errors: @ticket_type.errors, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize @ticket_type
      @ticket_type.destroy!
      render_success(status: :ok)
    end

    private

    def find_product
      manageable_events = Events::AuthorizationResolver.manageable_catalog_events(current_user)
      @product = Catalog::EventProduct.where(event_id: manageable_events.select(:id)).find(params[:event_product_id])
    end

    def find_ticket_type
      @ticket_type = @product.ticket_type || (raise ActiveRecord::RecordNotFound)
    end

    def ticket_type_params
      params.permit(
        :approval_mode, :audience, :date_selection, :waitlist_enabled,
        :transferable, :transfer_cutoff_seconds_before_start,
        :admissions_per_unit, :delegation_enabled, :delegation_validation_mode,
        :entry_validation_mode, :max_packages_per_user, :resale_enabled,
        :resale_cutoff_seconds_before_start, :resale_price_cap_type,
        :resale_fixed_cap_minor, :resale_fixed_cap_currency,
        :resale_percentage_cap_bps, :max_completed_resales
      )
    end
  end
end
