# frozen_string_literal: true

module Ticketing
  class AttendeeExportsController < Ticketing::ApplicationController
    skip_authorization only: :create

    before_action :ensure_idempotency_key_present
    before_action :load_event

    def create
      result = Ticketing::Exports::Request.call(
        actor: current_user,
        event: @event,
        session_jti: current_authentication_jti,
        raw_proof: params[:proof],
        idempotency_key:,
        row_mode: params[:row_mode],
        field_keys: params[:field_keys],
        filters: params[:filters],
        reason_code: params[:reason_code]
      )

      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Ticketing::AttendeeExportSerializer }
      )
    end

    private

    def load_event
      @event = Events::Event.find(params[:event_id])
    end
  end
end
