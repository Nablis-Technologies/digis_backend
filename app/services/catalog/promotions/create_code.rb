# frozen_string_literal: true

module Catalog
  module Promotions
    # Creates an event-scoped encrypted promotion code.
    #
    # The normalized plaintext is used only to derive the keyed lookup digest
    # and the one-time command result. The database and audit record retain no
    # plaintext code.
    class CreateCode < Core::BaseService
      include CommandSupport

      CodeResult = Data.define(:record, :plaintext)
      ATTRIBUTES = %i[label redemption_limit starts_at ends_at active].freeze

      def initialize(promotion:, actor:, attributes:, idempotency_key:)
        @promotion = promotion
        @actor = actor
        @attributes = normalize_hash(attributes)
        @raw_code = @attributes.delete(:code)
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        normalized_code = Catalog::PromotionCode.normalize_code(@raw_code)
        digest = request_digest(promotion_id: @promotion.id, attributes: @attributes, code: normalized_code)
        audit_key = command_audit_key("code-created", @promotion.id, @idempotency_key)

        ActiveRecord::Base.transaction do
          @promotion.lock!
          command_lock!("code-create", @promotion.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return replay_code(replay) if replay
          return failure(Core::Error.new(I18n.t("catalog.promotion_code.errors.promotion_unavailable"))) if @promotion.disabled?

          code = @promotion.promotion_codes.new(@attributes.slice(*ATTRIBUTES))
          code.code = normalized_code
          code.code_digest = Catalog::PromotionCode.code_digest_for(
            event_id: @promotion.event_id,
            code: normalized_code
          )
          return failure(promotion_error(code)) unless code.valid?

          code.save!
          record_command_audit!(
            audit_key:,
            action: "catalog.promotion.code_created",
            auditable: code,
            actor: @actor,
            request_digest: digest,
            audited_changes: { promotion_id: @promotion.id },
            metadata: { event_id: @promotion.event_id, promotion_id: @promotion.id, promotion_code_id: code.id }
          )
          success(CodeResult.new(record: code, plaintext: normalized_code))
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(promotion_error(error.record))
      end

      private

      def replay_code(metadata)
        code = Catalog::PromotionCode.find_by(id: metadata[:promotion_code_id])
        return success(CodeResult.new(record: code, plaintext: code.code)) if code

        failure(Core::Error.new(I18n.t("catalog.promotion.errors.replay_not_found")))
      end
    end
  end
end
