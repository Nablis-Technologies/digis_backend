# frozen_string_literal: true

require "securerandom"

module Ticketing
  module Scanners
    # Registers a scanner to an organization and returns its credential once.
    # Only the keyed digest is persisted; the plaintext token is intentionally
    # kept inside this result and never enters audit or serialized data.
    class RegisterDevice < Core::BaseService
      Result = Data.define(:device, :token)

      def initialize(organization:, actor:, device_identifier:, name: nil)
        @organization = organization
        @actor = actor
        @device_identifier = Core::KeyedDigest.normalize(device_identifier)
        @name = Core::KeyedDigest.normalize(name).presence
      end

      def call
        return failure(error(:device_identifier_required, :bad_request)) if device_identifier.blank?
        return failure(error(:registration_forbidden, :forbidden)) unless authorized?

        token = SecureRandom.hex(32)
        device = nil
        ActiveRecord::Base.transaction do
          device = Ticketing::ScannerDevice.create!(
            organization:,
            device_identifier:,
            name:,
            token_digest: Ticketing::ScannerDevice.token_digest_for(token:)
          )
          device.record_audit!(
            "ticketing.scanner_device.registered",
            actor:,
            audited_changes: { organization_id: organization.id, device_identifier: }
          )
        end

        success(Result.new(device:, token:))
      rescue ActiveRecord::RecordNotUnique
        failure(error(:device_identifier_taken, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_device, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :organization, :actor, :device_identifier, :name

      def authorized?
        Events::AuthorizationResolver.organization_admin?(actor, organization)
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
