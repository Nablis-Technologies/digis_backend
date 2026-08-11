# frozen_string_literal: true

module Ticketing
  class AttendeeExportsController < Ticketing::ApplicationController
    skip_authorization only: :create

    before_action :ensure_idempotency_key_present, only: :create
    before_action :load_event, only: :create
    before_action :load_export, only: %i[show download_authorizations]

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

    def show
      authorize @export
      render_success(
        data: @export,
        serializer_options: { serializer: Ticketing::AttendeeExportSerializer }
      )
    end

    def download_authorizations
      authorize @export, :download_authorizations?
      result = Ticketing::Exports::AuthorizeDownload.call(
        attendee_export_id: @export.id,
        actor: current_user,
        session_jti: current_authentication_jti,
        raw_proof: params.require(:proof)
      )
      return render_service_result(result) if result.failure?

      render_success(
        :"ticketing.attendee_exports.success.download_authorization",
        data: result.value
      )
    end

    private

    def load_event
      @event = Events::Event.find(params[:event_id])
    end

    def load_export
      @export = Ticketing::AttendeeExport.includes(:event).find(params[:id])
    end
  end
end
