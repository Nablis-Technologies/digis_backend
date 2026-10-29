# frozen_string_literal: true

module Ticketing
  module PurchaseLimits
    # Reserves package units against one verified user before checkout or
    # issuance. Inventory and payment are intentionally outside this command.
    class Reserve < Core::BaseService
      include Support

      def initialize(registration:, user:, quantity:, expires_at:, idempotency_key:)
        @registration = registration
        @user = user
        @quantity = quantity.to_i
        @expires_at = expires_at
        @idempotency_key = idempotency_key
      end

      def call
        validate_request!
        allocations = ActiveRecord::Base.transaction do
          ticket_type = Ticketing::TicketType.lock.find(registration.ticket_type_id)
          validate_identity!(registration, user)
          scope_event_date_id = limit_scope_for(ticket_type, registration)
          lock_scope!(ticket_type, scope_event_date_id, user)
          release_expired!(ticket_type, scope_event_date_id)
          reserve_units!(ticket_type, scope_event_date_id)
        end

        success(allocations)
      rescue Support::BusinessFailure => error
        error.result
      rescue ArgumentError => error
        failure(Core::BusinessError.new(error.message, code: "invalid_idempotency_key", status: :unprocessable_entity))
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::BusinessError.new(
          I18n.t("ticketing.purchase_limits.errors.invalid_allocation"),
          code: "invalid_allocation",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        ))
      rescue ActiveRecord::RecordNotUnique
        failure(conflict)
      end

      private

      attr_reader :registration, :user, :quantity, :expires_at, :idempotency_key

      def validate_request!
        raise ArgumentError, I18n.t("ticketing.purchase_limits.errors.idempotency_key_required") if idempotency_key.blank?
        fail BusinessFailure, failure("purchase_limit_quantity_invalid", "quantity_invalid") unless quantity.positive?
        fail BusinessFailure, failure("purchase_limit_expiry_invalid", "expiry_invalid") unless expires_at.present? && expires_at > Time.current
      end

      def release_expired!(ticket_type, scope_event_date_id)
        PurchaseLimitAllocation
          .where(ticket_type:, scope_event_date_id:, status: "reserved")
          .where("expires_at <= ?", Time.current)
          .includes(:registration, :ticket_type)
          .lock
          .find_each do |allocation|
            allocation.update!(
              status: "released",
              expires_at: nil,
              released_at: Time.current,
              release_reason: "expired"
            )
          end
      end

      def reserve_units!(ticket_type, scope_event_date_id)
        replay = allocations_for_key(ticket_type, scope_event_date_id)
        if replay.any?
          return replay.sort_by(&:unit_number) if replay.size == quantity && replay.all? { |allocation| allocation.registration_id == registration.id }

          fail BusinessFailure, conflict
        end

        limit = effective_limit(ticket_type, scope_event_date_id)
        return success([]).value if limit.nil?

        existing = registration_allocations.lock.order(:unit_number).to_a
        reusable = existing.first(quantity)
        countable = countable_allocations(ticket_type, scope_event_date_id).count
        needed = quantity - reusable.count { |allocation| allocation.status.in?(%w[reserved committed]) }
        if countable + needed > limit
          fail BusinessFailure, failure("purchase_limit_exceeded", "exceeded")
        end

        allocations = (1..quantity).map do |unit_number|
          allocation = existing.find { |row| row.unit_number == unit_number }
          reserve_unit!(allocation, ticket_type, scope_event_date_id, unit_number)
        end
        allocations
      end

      def registration_allocations
        PurchaseLimitAllocation
          .where(registration_id: registration.id)
          .includes(:registration, :ticket_type)
      end

      def allocations_for_key(ticket_type, scope_event_date_id)
        PurchaseLimitAllocation
          .where(ticket_type:, user:, scope_event_date_id:)
          .where("idempotency_key LIKE ?", "#{key_digest}:%")
          .lock
          .to_a
      end

      def countable_allocations(ticket_type, scope_event_date_id)
        PurchaseLimitAllocation
          .where(ticket_type:, user:, scope_event_date_id:)
          .countable
      end

      def effective_limit(ticket_type, scope_event_date_id)
        override = PurchaseLimitOverride.find_by(
          registration_id: registration.id,
          ticket_type_id: ticket_type.id,
          user_id: user.id,
          scope_event_date_id:
        )
        return ticket_type.max_packages_per_user.to_i + override.additional_packages if override && ticket_type.max_packages_per_user.present?
        return override.additional_packages if override

        ticket_type.max_packages_per_user
      end

      def reserve_unit!(allocation, ticket_type, scope_event_date_id, unit_number)
        expected_key = "#{key_digest}:#{unit_number}"
        if allocation&.reserved?
          return allocation if allocation.expires_at == expires_at && allocation.idempotency_key == expected_key

          allocation.update!(expires_at:, idempotency_key: expected_key)
          return allocation
        end
        return allocation if allocation&.committed?

        attributes = {
          ticket_type:,
          user:,
          scope_event_date_id:,
          registration:,
          unit_number:,
          status: "reserved",
          expires_at:,
          committed_at: nil,
          released_at: nil,
          release_reason: nil,
          idempotency_key: expected_key
        }

        if allocation
          allocation.update!(attributes)
          allocation
        else
          PurchaseLimitAllocation.create!(attributes)
        end
      end
    end
  end
end
