# frozen_string_literal: true

module Ticketing
  module Scanners
    # Establishes the dual-principal scanner context used by later admission
    # commands: the signed-in operator and the event-scoped device assignment.
    # Ticket eligibility is deliberately outside this service.
    class Authenticate < Core::BaseService
      Result = Data.define(:device, :assignment)

      def initialize(operator:, device_identifier:, token:, event:, now: Time.current)
        @operator = operator
        @device_identifier = Core::KeyedDigest.normalize(device_identifier)
        @token = token.to_s
        @event = event
        @now = now
      end

      def call
        return failure(error(:device_identifier_required, :bad_request)) if device_identifier.blank?

        device = Ticketing::ScannerDevice.find_by(device_identifier:)
        digest = Ticketing::ScannerDevice.token_digest_for(token:)
        stored_digest = device&.token_digest || ("0" * 64)
        token_matches = Ticketing::ScannerDevice.constant_time_digest_match?(stored_digest, digest)
        return failure(error(:token_required, :unauthorized)) if token.blank?
        return failure(error(:authentication_failed, :unauthorized)) unless device && token_matches
        return failure(error(:device_inactive, :unauthorized)) unless device.active?

        assignment = device.assignments.where(event:).order(created_at: :desc).first
        return failure(error(:assignment_not_found, :unauthorized)) if assignment.nil?
        return failure(error(:assignment_inactive, :unauthorized)) unless assignment.active?
        return failure(error(:assignment_outside_window, :unauthorized)) unless assignment.active_now?(now)
        return failure(error(:operator_forbidden, :forbidden)) unless policy_allows?(assignment)

        device.update!(last_seen_at: now)
        success(Result.new(device:, assignment:))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :operator, :device_identifier, :token, :event, :now

      def policy_allows?(assignment)
        Pundit.authorize(
          operator,
          assignment,
          :show?,
          policy_class: Ticketing::ScannerDeviceAssignmentPolicy
        )
        true
      rescue Pundit::NotAuthorizedError
        false
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
