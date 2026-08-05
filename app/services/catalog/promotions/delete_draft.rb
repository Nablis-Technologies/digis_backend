# frozen_string_literal: true

module Catalog
  module Promotions
    # Discards a draft promotion and its dependent code/scope rows.
    #
    # Only drafts may be permanently removed. The deletion audit is recorded
    # before destruction and the command remains safe to replay after removal.
    class DeleteDraft < Core::BaseService
      include CommandSupport

      def initialize(promotion:, actor:, idempotency_key:, promotion_id: nil)
        @promotion = promotion
        @actor = actor
        @promotion_id = promotion_id || promotion&.id
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        digest = request_digest(promotion_id: @promotion_id)
        audit_key = command_audit_key("deleted", @promotion_id, @idempotency_key)
        return replay_or_not_found(audit_key, digest) unless @promotion
        return replay_or_not_found(audit_key, digest) if @promotion.destroyed?

        ActiveRecord::Base.transaction do
          @promotion.lock!
          command_lock!("delete", @promotion.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return success if replay
          return failure(Core::Error.new(I18n.t("catalog.promotion.errors.delete_forbidden"))) unless @promotion.draft?

          record_command_audit!(
            audit_key:,
            action: "catalog.promotion.deleted",
            auditable: @promotion,
            actor: @actor,
            request_digest: digest,
            audited_changes: { status: [ "draft", "deleted" ] },
            metadata: { event_id: @promotion.event_id, promotion_id: @promotion.id }
          )
          @promotion.destroy!
          success
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(promotion_error(error.record))
      end

      private

      def replay_or_not_found(audit_key, digest)
        return success if replay_metadata(audit_key, digest)

        failure(Core::Error.new(I18n.t("catalog.promotion.errors.not_found")))
      end
    end
  end
end
