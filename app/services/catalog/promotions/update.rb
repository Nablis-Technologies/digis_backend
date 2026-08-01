# frozen_string_literal: true

module Catalog
  module Promotions
    # Updates a draft definition and replaces its product scope atomically.
    #
    # Published and disabled versions are immutable. A nil product_ids value
    # preserves the existing scope, while an empty array explicitly clears it.
    # The update, scope replacement, and audit entry share one transaction.
    class Update < Core::BaseService
      include CommandSupport

      ATTRIBUTES = Create::ATTRIBUTES - %i[supersedes_promotion_id version status].freeze

      def initialize(promotion:, actor:, attributes:, product_ids: nil, idempotency_key:)
        @promotion = promotion
        @actor = actor
        @attributes = normalize_hash(attributes)
        @product_ids = product_ids
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        @product_ids = normalize_product_ids(@product_ids)
        digest = request_digest(promotion_id: @promotion.id, attributes: @attributes, product_ids: @product_ids)
        audit_key = command_audit_key("updated", @promotion.id, @idempotency_key)

        ActiveRecord::Base.transaction do
          @promotion.lock!
          command_lock!("update", @promotion.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return success(@promotion.reload) if replay
          return failure(Core::Error.new(I18n.t("catalog.promotion.errors.update_forbidden"))) unless @promotion.draft?

          # Keep nil distinct from [] so omitted scope and explicit clearing
          # remain different API operations.
          products = event_products if @product_ids
          before = @promotion.attributes.slice(*ATTRIBUTES.map(&:to_s))
          @promotion.assign_attributes(@attributes.slice(*ATTRIBUTES))
          return failure(promotion_error(@promotion)) unless @promotion.valid?

          @promotion.save!
          if products
            @promotion.promotion_products.delete_all
            products.each { |product| @promotion.promotion_products.create!(event_product: product) }
          end
          record_command_audit!(
            audit_key:,
            action: "catalog.promotion.updated",
            auditable: @promotion,
            actor: @actor,
            request_digest: digest,
            audited_changes: attribute_changes(before, @promotion.attributes),
            metadata: { event_id: @promotion.event_id, promotion_id: @promotion.id }
          )
          success(@promotion.reload)
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(promotion_error(error.record))
      end

      private

      def event_products
        products = Catalog::EventProduct.where(event_id: @promotion.event_id, id: @product_ids).to_a
        return products if products.size == @product_ids.size

        raise Core::Error, I18n.t("catalog.promotion.errors.event_mismatch")
      end
    end
  end
end
