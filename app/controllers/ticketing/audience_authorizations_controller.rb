# frozen_string_literal: true

module Ticketing
  # Public read-only audience gate check for codes and invitation tokens.
  class AudienceAuthorizationsController < Ticketing::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization only: :create

    def create
      ticket_type = Ticketing::TicketType.find(params.require(:ticket_type_id))
      result = Ticketing::Audience::Authorize.call(
        ticket_type:,
        access_code: params[:access_code],
        invitation: params[:invitation_token],
        user: current_user
      )

      if result.success?
        render_success(data: result.value.slice(:authorized, :reason))
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end
  end
end
