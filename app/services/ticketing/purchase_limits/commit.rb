# frozen_string_literal: true

module Ticketing
  module PurchaseLimits
    # Converts a buyer's active package-unit hold into historical ownership.
    class Commit < Core::BaseService
      include Support

      def initialize(registration:, user:, idempotency_key:, unit_numbers: nil)
        @registration = registration
        @user = user
        @idempotency_key = idempotency_key
        @unit_numbers = unit_numbers
      end

      def call
        validate_identity!(registration, user)
        allocations = ActiveRecord::Base.transaction do
          ticket_type = Ticketing::TicketType.lock.find(registration.ticket_type_id)
          scope_event_date_id = limit_scope_for(ticket_type, registration)
          lock_scope!(ticket_type, scope_event_date_id, user)
          audit_key = "ticketing-purchase-limit-commit-#{registration.id}-#{key_digest}"
          current = scoped_allocations(scope_event_date_id).lock.order(:unit_number).to_a
          return success(current) if Core::AuditLog.exists?(audit_key:)
          fail BusinessFailure, failure("purchase_limit_allocations_missing", "allocations_missing") if current.empty?

          current.each do |allocation|
            next if allocation.committed?
            fail BusinessFailure, failure("purchase_limit_allocation_not_reservable", "allocation_not_reservable") unless allocation.reserved?
            fail BusinessFailure, failure("purchase_limit_reservation_expired", "reservation_expired") if allocation.expires_at <= Time.current

            allocation.update!(status: "committed", expires_at: nil, committed_at: Time.current)
          end
          record_audit!(audit_key, current)
          current
        end

        success(allocations)
      rescue Support::BusinessFailure => error
        error.result
      rescue ArgumentError => error
        failure(Core::BusinessError.new(error.message, code: "invalid_idempotency_key", status: :unprocessable_entity))
      end

      private

      attr_reader :registration, :user, :idempotency_key, :unit_numbers

      def scoped_allocations(scope_event_date_id)
        scope = PurchaseLimitAllocation
          .where(registration:, user:, scope_event_date_id:)
          .includes(:registration, :ticket_type)
        scope = scope.where(unit_number: Array(unit_numbers)) if unit_numbers.present?
        scope
      end

      def record_audit!(audit_key, allocations)
        Core::Audit::Record.call(
          audit_key:,
          action: "ticketing.purchase_limit_allocation.committed",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          actor_type: user.class.name,
          actor_id: user.id,
          audited_changes: { status: [ "reserved", "committed" ] },
          metadata: { registration_id: registration.id, unit_numbers: allocations.map(&:unit_number) }
        ).value
      end
    end
  end
end
