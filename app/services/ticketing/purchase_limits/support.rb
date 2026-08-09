# frozen_string_literal: true

module Ticketing
  module PurchaseLimits
    # Shared validation and locking primitives for package-unit limit commands.
    module Support
      private

      def key_digest
        @key_digest ||= Core::IdempotencyKey.new(idempotency_key).digest
      end

      def validate_identity!(registration, user)
        return if registration.user_id == user.id

        fail BusinessFailure, failure("purchase_limit_user_mismatch", "user_mismatch")
      end

      def limit_scope_for(ticket_type, registration)
        return nil if ticket_type.date_selection == "fixed"

        return registration.selected_event_date_id if registration.selected_event_date_id.present?

        fail BusinessFailure, failure("purchase_limit_date_required", "date_required")
      end

      def lock_scope!(ticket_type, scope_event_date_id, user)
        Core::Database::AdvisoryLock.acquire!("purchase-limit", ticket_type.id, scope_event_date_id || "all", user.id)
      end

      def failure(code, translation_key, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("ticketing.purchase_limits.errors.#{translation_key}"),
          code:,
          status:
        )
      end

      def conflict(code = "purchase_limit_idempotency_conflict")
        failure(code, "idempotency_conflict")
      end

      class BusinessFailure < StandardError
        attr_reader :result

        def initialize(error)
          @result = Core::BaseService::Result.failure(error)
          super(error.message)
        end
      end
    end
  end
end
