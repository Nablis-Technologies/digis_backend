# frozen_string_literal: true

require "json"

module Ticketing
  module Scanner
    # Serves the event-scoped full snapshot or cursor-based delta after the
    # shared dual-principal scanner authentication has established an active
    # assignment. The response is read-only; scanners acknowledge cursors only
    # after their own local transaction commits.
    class EventSyncController < Ticketing::ApplicationController
      include Ticketing::ScannerAuthenticated

      skip_authorization only: :show

      def show
        result = if params.fetch(:mode, "full") == "full"
          Ticketing::ScannerSync::BuildSnapshot.call(assignment: current_scanner_assignment)
        elsif params[:mode] == "delta"
          build_delta
        else
          failure_for(:invalid_mode)
        end

        return render_error(
          result.error.message,
          status: result.error.status,
          code: result.error.code,
          errors: result.error.errors,
          meta: result.error.meta
        ) if result.failure?

        render_success(
          data: Ticketing::ScannerSyncSerializer.call(result.value)
        )
      end

      private

      def build_delta
        cursors = parse_cursors
        return cursors if cursors.failure?

        Ticketing::ScannerSync::BuildDelta.call(
          assignment: current_scanner_assignment,
          cursors: cursors.value
        )
      end

      def parse_cursors
        value = params[:cursors]
        value = JSON.parse(value) if value.is_a?(String)
        return failure_for(:scanner_cursors_required) unless value.respond_to?(:to_h)

        Core::BaseService::Result.success(value.to_h)
      rescue JSON::ParserError, TypeError
        failure_for(:scanner_cursors_required)
      end

      def failure_for(key)
        Core::BaseService::Result.failure(
          Core::BusinessError.new(
            I18n.t("ticketing.scanner_sync.errors.#{key}"),
            code: key.to_s,
            status: :bad_request
          )
        )
      end
    end
  end
end
