# frozen_string_literal: true

module Catalog
  module Promotions
    # Publishes a draft promotion and disables its superseded active version.
    #
    # Promotion status changes and lineage checks run under locks in one
    # transaction, so only one version can remain active after publication and
    # a replay cannot create a second audit transition.
    class PublishVersion < Core::BaseService
      include CommandSupport

      def initialize(promotion:, actor:, idempotency_key:)
        @promotion = promotion
        @actor = actor
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        digest = request_digest(promotion_id: @promotion.id, action: "publish")
        audit_key = command_audit_key("published", @promotion.id, @idempotency_key)

        ActiveRecord::Base.transaction do
          @promotion.lock!
          command_lock!("publish", @promotion.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return success(@promotion.reload) if replay
          return success(@promotion.reload) if @promotion.active?
          return failure(Core::Error.new(I18n.t("catalog.promotion.errors.publish_forbidden"))) unless @promotion.draft?

          superseded = @promotion.supersedes_promotion
          if superseded
            superseded.lock!
            return failure(Core::Error.new(I18n.t("catalog.promotion.errors.invalid_version_lineage"))) unless superseded.event_id == @promotion.event_id

            superseded.update!(status: "disabled") if superseded.active?
          end

          @promotion.update!(status: "active")
          record_command_audit!(
            audit_key:,
            action: "catalog.promotion.published",
            auditable: @promotion,
            actor: @actor,
            request_digest: digest,
            audited_changes: { status: [ "draft", "active" ] },
            metadata: {
              event_id: @promotion.event_id,
              promotion_id: @promotion.id,
              superseded_promotion_id: superseded&.id
            }
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
