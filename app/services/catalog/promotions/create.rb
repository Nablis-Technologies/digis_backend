# frozen_string_literal: true

module Catalog
  module Promotions
    # Creates a draft promotion version and its optional product scope.
    #
    # The predecessor must belong to the same event, and the next version is
    # derived from it rather than trusted from the request. Product scope,
    # promotion rows, and the creation audit are committed atomically; replay
    # of the same idempotency key returns the original promotion.
    class Create < Core::BaseService
      include CommandSupport

      ATTRIBUTES = %i[
        name type percentage_basis_points fixed_amount_minor currency
        minimum_subtotal_minor maximum_discount_minor redemption_limit
        per_user_limit starts_at ends_at supersedes_promotion_id version
      ].freeze

      def initialize(event:, actor:, attributes:, product_ids: [], idempotency_key:)
        @event = event
        @actor = actor
        @attributes = normalize_hash(attributes)
        @product_ids = product_ids
        @idempotency_key = idempotency_key.to_s.strip
      end

      def call
        require_idempotency_key!(@idempotency_key)
        @product_ids = normalize_product_ids(@product_ids) || []
        digest = request_digest(event_id: @event.id, attributes: @attributes, product_ids: @product_ids)
        audit_key = command_audit_key("created", @event.id, @idempotency_key)

        ActiveRecord::Base.transaction do
          command_lock!("create", @event.id, @idempotency_key)
          replay = replay_metadata(audit_key, digest)
          return replay_promotion(replay) if replay

          predecessor = superseded_promotion
          validate_version_lineage!(predecessor)
          products = event_products
          promotion = @event.promotions.new(promotion_attributes(predecessor))
          return failure(promotion_error(promotion)) unless promotion.valid?

          promotion.save!
          products.each { |product| promotion.promotion_products.create!(event_product: product) }
          record_creation_audit!(promotion, audit_key, digest)
          success(promotion.reload)
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(promotion_error(error.record))
      end

      private

      # Scope predecessor lookup to the event so lineage cannot cross events.
      def superseded_promotion
        id = @attributes[:supersedes_promotion_id]
        return unless id

        @event.promotions.lock.find_by(id: id) ||
          raise(Core::Error, I18n.t("catalog.promotion.errors.superseded_not_found"))
      end

      # Version is server-owned; an optional request value is only a consistency
      # check for service callers that already know the expected next version.
      def validate_version_lineage!(predecessor)
        expected = predecessor ? predecessor.version + 1 : 1
        return if @attributes[:version].blank? || @attributes[:version].to_i == expected

        raise Core::Error, I18n.t("catalog.promotion.errors.invalid_version_lineage")
      end

      # Resolve products through the current event before creating scope rows.
      def event_products
        products = Catalog::EventProduct.where(event_id: @event.id, id: @product_ids).to_a
        return products if products.size == @product_ids.size

        raise Core::Error, I18n.t("catalog.promotion.errors.event_mismatch")
      end

      def promotion_attributes(predecessor)
        @attributes.slice(*ATTRIBUTES).except(:supersedes_promotion_id, :version).merge(
          status: "draft",
          currency: @attributes[:currency].presence || @event.currency,
          version: predecessor ? predecessor.version + 1 : 1,
          supersedes_promotion: predecessor
        )
      end

      def replay_promotion(metadata)
        promotion = Catalog::Promotion.find_by(id: metadata[:promotion_id])
        return success(promotion) if promotion

        failure(Core::Error.new(I18n.t("catalog.promotion.errors.replay_not_found")))
      end

      def record_creation_audit!(promotion, audit_key, digest)
        record_command_audit!(
          audit_key:,
          action: "catalog.promotion.created",
          auditable: promotion,
          actor: @actor,
          request_digest: digest,
          audited_changes: promotion.attributes.slice("name", "type", "status", "version", "currency"),
          metadata: { event_id: @event.id, promotion_id: promotion.id }
        )
      end
    end
  end
end
