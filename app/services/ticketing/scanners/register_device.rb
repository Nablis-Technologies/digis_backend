# frozen_string_literal: true

module Ticketing
  module Scanners
    # Registers or reuses a PWA installation under the event-owned scanner grant.
    # A device is an identity record; authentication belongs to ScannerSession.
    class RegisterDevice < Core::BaseService
      Result = Data.define(:device, :reused)

      def initialize(event:, delegated_grant:, device_identifier:, name: nil)
        @event = event
        @delegated_grant = delegated_grant
        @device_identifier = Core::KeyedDigest.normalize(device_identifier)
        @name = Core::KeyedDigest.normalize(name).presence
      end

      def call
        return failure(error(:device_identifier_required, :bad_request)) if device_identifier.blank?
        return failure(error(:registration_forbidden, :forbidden)) unless delegated_grant&.valid_for?(
          event:, role: "scanner"
        )
        return failure(error(:device_scope_forbidden, :forbidden)) if event.status.in?(%w[cancelled completed])

        outcome = nil
        ActiveRecord::Base.transaction do
          event.lock!
          Core::Database::AdvisoryLock.acquire!("ticketing-scanner-device-register", device_identifier)
          device = Ticketing::ScannerDevice.find_by(device_identifier:)
          if device
            outcome = if !device_in_event_scope?(device)
              failure(error(:device_scope_forbidden, :forbidden))
            elsif !device.active?
              failure(error(:device_inactive, :conflict))
            else
              success(Result.new(device:, reused: true))
            end
            next
          end

          device = Ticketing::ScannerDevice.create!(organization:, device_identifier:, name:)
          device.record_audit!(
            "ticketing.scanner_device.registered",
            actor: grantor,
            audited_changes: { organization_id: organization.id, device_identifier: },
            metadata: { invitation_id: delegated_grant.source_id, event_id: event.id }
          )
          outcome = success(Result.new(device:, reused: false))
        end

        outcome
      rescue ActiveRecord::RecordNotUnique
        failure(error(:device_identifier_taken, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :event, :delegated_grant, :device_identifier, :name

      def organization
        @organization ||= Organizations::Organization.find(event.organization_id)
      end

      def device_in_event_scope?(device)
        return true if device.organization_id == event.organization_id

        Events::EventOrganization.exists?(
          event_id: event.id,
          organization_id: device.organization_id,
          status: "active"
        )
      end

      def grantor
        @grantor ||= Core::User.find(delegated_grant.grantor_id)
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
