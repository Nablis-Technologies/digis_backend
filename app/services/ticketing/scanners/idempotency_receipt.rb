# frozen_string_literal: true

module Ticketing
  module Scanners
    # Claims a database-backed lifecycle request identity. A unique operation
    # and key digest is the concurrency boundary; audit rows remain evidence.
    class IdempotencyReceipt < Core::BaseService
      Result = Data.define(:receipt, :replayed) do
        def replayed? = replayed
      end

      def initialize(operation:, device:, actor:, idempotency_key:, request_identity: nil)
        @operation = operation
        @device = device
        @actor = actor
        @request_identity = request_identity
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      rescue ArgumentError
        @invalid_key = true
      end

      def call
        return failure(error(:invalid_idempotency_key, :bad_request)) if invalid_key?

        receipt = nil
        Ticketing::ScannerDeviceIdempotency.transaction(requires_new: true) do
          receipt = Ticketing::ScannerDeviceIdempotency.create!(
            scanner_device: device,
            operation:,
            idempotency_key_digest: idempotency_key.digest,
            request_digest:
          )
        end
        success(Result.new(receipt:, replayed: false))
      rescue ActiveRecord::RecordNotUnique
        replay_or_conflict
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_idempotency_key, :bad_request, errors: exception.record.errors.to_hash))
      end

      def self.request_digest(operation:, device:, actor:, request_identity: nil)
        Core::KeyedDigest.digest(
          namespace: "ticketing-scanner-device-idempotency",
          value: ActiveSupport::JSON.encode(
            operation:, device_id: device.id, actor_id: actor.id, request_identity:
          )
        )
      end

      private

      attr_reader :operation, :device, :actor, :idempotency_key, :request_identity
      attr_reader :invalid_key

      def request_digest
        self.class.request_digest(operation:, device:, actor:, request_identity:)
      end

      def invalid_key?
        invalid_key == true
      end

      def replay_or_conflict
        receipt = Ticketing::ScannerDeviceIdempotency.find_by(
          operation:, idempotency_key_digest: idempotency_key.digest
        )
        return failure(error(:idempotency_conflict, :conflict)) unless receipt
        return failure(error(:idempotency_conflict, :conflict)) unless receipt.scanner_device_id == device.id
        return failure(error(:idempotency_conflict, :conflict)) unless receipt.request_digest == request_digest

        success(Result.new(receipt:, replayed: true))
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
