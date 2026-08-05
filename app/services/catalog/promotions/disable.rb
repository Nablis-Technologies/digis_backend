# frozen_string_literal: true

module Catalog
  module Promotions
    # Disables an active promotion version without changing its evidence.
    #
    # Disabling is a terminal lifecycle transition: the immutable promotion and
    # its quote evidence remain available for historical checkout verification.
    class Disable < Core::BaseService
      include CommandSupport

      def initialize(promotion:, actor:, idempotency_key:)
        @promotion = promotion
        @actor = actor
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        digest = request_digest(promotion_id: @promotion.id, action: "disable")
        audit_key = command_audit_key("disabled", @promotion.id, @idempotency_key)

        ActiveRecord::Base.transaction do
          @promotion.lock!
          command_lock!("disable", @promotion.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return success(@promotion.reload) if replay
          return success(@promotion.reload) if @promotion.disabled?
          return failure(Core::Error.new(I18n.t("catalog.promotion.errors.disable_forbidden"))) unless @promotion.active?

          @promotion.update!(status: "disabled")
          record_command_audit!(
            audit_key:,
            action: "catalog.promotion.disabled",
            auditable: @promotion,
            actor: @actor,
            request_digest: digest,
            audited_changes: { status: [ "active", "disabled" ] },
            metadata: { event_id: @promotion.event_id, promotion_id: @promotion.id }
          )
          success(@promotion.reload)
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(promotion_error(error.record))
      end
    end
  end
end
