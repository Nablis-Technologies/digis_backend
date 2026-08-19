# frozen_string_literal: true

module Admin
  module System
    # Checks only local application dependencies and returns a deliberately
    # small readiness projection. Provider reachability and repair belong to
    # reconciliation, not this authenticated endpoint.
    class Readiness < Core::BaseService
      OUTBOX_WARNING_AGE = 5.minutes
      COMPONENTS = {
        database: :database_ready?,
        encryption: :encryption_ready?,
        outbox: :outbox_ready?,
        queue: :queue_ready?,
        storage: :storage_ready?
      }.freeze

      def call
        components = COMPONENTS.transform_values { |check| component_status(check) }
        status = components.values.all? { |value| value == "ok" } ? "ok" : "degraded"
        success(status:, components:)
      end

      private

      def component_status(check)
        public_send(check) ? "ok" : "degraded"
      rescue StandardError
        "degraded"
      end

      def database_ready?
        Core::ApplicationRecord.connection.select_value("SELECT 1").to_i == 1
      end

      def encryption_ready?
        encryption = Rails.application.config.active_record.encryption
        %i[primary_key deterministic_key key_derivation_salt].all? do |key|
          encryption.public_send(key).present?
        end
      end

      def outbox_ready?
        !Core::OutboxEvent
          .where(published_at: nil)
          .where("available_at <= ?", Time.current - OUTBOX_WARNING_AGE)
          .exists?
      end

      def queue_ready?
        return false unless defined?(SolidQueue::Job)

        SolidQueue::Job.connection.select_value("SELECT 1").to_i == 1
      end

      def storage_ready?
        service = ActiveStorage::Blob.service
        return false unless service

        return service.root.present? if service.respond_to?(:root)
        return service.bucket.present? if service.respond_to?(:bucket)

        false
      end
    end
  end
end
