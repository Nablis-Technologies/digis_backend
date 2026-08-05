# frozen_string_literal: true

module Catalog
  module Promotions
    # Explicitly reveals a stored canonical code and audits the action without
    # persisting the plaintext in audit metadata.
    #
    # This is the only command that returns an existing code after creation;
    # callers must provide a fresh idempotency key for each explicit reveal.
    class RevealCode < Core::BaseService
      include CommandSupport

      def initialize(promotion_code:, actor:, idempotency_key:)
        @promotion_code = promotion_code
        @actor = actor
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        digest = request_digest(promotion_code_id: @promotion_code.id)
        audit_key = command_audit_key("code-revealed", @promotion_code.id, @idempotency_key)

        ActiveRecord::Base.transaction do
          @promotion_code.lock!
          command_lock!("code-reveal", @promotion_code.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return success(@promotion_code.code) if replay

          record_command_audit!(
            audit_key:,
            action: "catalog.promotion.code_revealed",
            auditable: @promotion_code,
            actor: @actor,
            request_digest: digest,
            audited_changes: { revealed: true },
            metadata: { promotion_id: @promotion_code.promotion_id, promotion_code_id: @promotion_code.id }
          )
          success(@promotion_code.code)
        end
      rescue Core::Error => error
        failure(error)
      end
    end
  end
end
