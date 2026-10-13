# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # Stops serving under the same surface lock used by purchase creation, then
    # records the unserved paid obligation before the transaction commits.
    class Cancel < Core::BaseService
      Result = Data.define(:placement, :refund, :refund_amount_minor, :replayed)

      def initialize(placement:, actor: nil, idempotency_key:, reason_code: "featured_placement_cancelled",
        system: false, at: Time.current)
        @placement_id = placement.id
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @reason_code = reason_code.to_s
        @system = system
        @at = at.to_time.utc
      end

      def call
        key = Core::IdempotencyKey.new(raw_idempotency_key)
        return failure(error(:cancellation_forbidden, status: :forbidden)) unless authorized?

        result = ActiveRecord::Base.transaction do
          placement = Marketing::FeaturedPlacement.find(placement_id)
          Core::Database::AdvisoryLock.acquire!("marketing", "featured_placements", placement.surface)
          event = Events::Event.lock.find(placement.event_id)
          locked = Marketing::FeaturedPlacement.lock.find(placement.id)
          command_digest = idempotency_digest(key, locked)
          digest = request_digest(locked)
          audit = Core::AuditLog.find_by(audit_key: audit_key(command_digest))
          if audit
            next replay_result(locked, audit, request_digest: digest)
          end
          unless locked.status.in?(%w[pending_payment scheduled active])
            next failure(error(:placement_not_cancellable, status: :conflict))
          end

          purchase = billing_purchase_for(locked)
          next failure(error(:billing_purchase_unavailable, status: :conflict)) unless purchase
          payments = Orders::Payment.where(billing_purchase_id: purchase.id).order(:id).lock.to_a
          purchase.lock!

          accepted_payment = payments.reverse.find { |payment| payment.accepted_at.present? && payment.status == "succeeded" }
          amount = refund_amount(locked, purchase, accepted_payment)
          refund = create_refund!(locked, purchase, accepted_payment, amount, command_digest:) if amount.positive?
          locked.update!(status: "cancelled", cancelled_at: at)
          cancel_unpaid_purchase!(purchase) unless purchase.paid?
          record_audit!(locked, event, refund, amount, command_digest:, request_digest: digest)
          success(Result.new(locked, refund, amount, false))
        end
        result
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, status: :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error(:placement_not_found, status: :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_placement, errors: exception.record.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        replay_after_conflict
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, status: :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :placement_id, :actor, :raw_idempotency_key, :reason_code, :system, :at

      def authorized?
        return true if system
        return false unless actor

        placement = Marketing::FeaturedPlacement.find_by(id: placement_id)
        placement && (actor.super_admin? || actor.has_role_in?(Organizations::Organization.find(placement.organization_id), :owner, :admin))
      end

      def idempotency_digest(key, placement)
        Core::KeyedDigest.digest(
          namespace: "marketing-featured-placement-cancel/#{placement.id}/#{actor&.id || 'system'}",
          value: key.to_s
        )
      end

      def request_digest(placement)
        Core::KeyedDigest.digest(
          namespace: "marketing-featured-placement-cancel-request",
          value: ActiveSupport::JSON.encode(placement_id: placement.id, reason_code:)
        )
      end

      def audit_key(command_digest)
        "marketing-featured-placement-cancel-#{command_digest}"
      end

      def billing_purchase_for(placement)
        Orders::BillingPurchase.find_by(
          source_type: "Marketing::FeaturedPlacement", source_id: placement.id
        )
      end

      def refund_amount(placement, purchase, payment)
        return 0 unless purchase.status == "paid"
        return 0 unless payment

        prior = Orders::Refund.where(billing_purchase_id: purchase.id, status: Orders::Refund::OUTSTANDING_STATUSES)
          .sum(:amount_minor)
        [ placement.refundable_amount_minor(at:) - prior, 0 ].max
      end

      def create_refund!(placement, purchase, payment, amount, command_digest:)
        result = Orders::CreateBillingPurchaseRefund.call(
          payment:, billing_purchase: purchase, amount_minor: amount, reason_code:,
          actor:, idempotency_key: "featured-placement-refund-#{command_digest}", at:
        )
        raise result.error if result.failure?

        placement.update!(refund_id: result.value.refund.id)
        result.value.refund
      end

      def cancel_unpaid_purchase!(purchase)
        return unless purchase.status.in?(%w[created pending_payment])

        purchase.update!(status: "cancelled")
      end

      def record_audit!(placement, event, refund, amount, command_digest:, request_digest:)
        result = Core::Audit::Record.call(
          audit_key: audit_key(command_digest), action: "marketing.featured_placement.cancelled",
          auditable_type: placement.class.name, auditable_id: placement.id,
          actor_type: actor&.class&.name, actor_id: actor&.id,
          audited_changes: { status: [ "pending_or_serving", "cancelled" ] },
          metadata: {
            event_id: event.id, refund_id: refund&.id, refund_amount_minor: amount,
            reason_code:, request_digest:
          }
        )
        raise result.error if result.failure?
      end

      def replay_result(placement, audit, request_digest:)
        return failure(error(:idempotency_conflict, status: :conflict)) unless audit.metadata.to_h["request_digest"] == request_digest

        refund = placement.refund_id && Orders::Refund.find_by(id: placement.refund_id)
        success(Result.new(placement, refund, refund&.amount_minor || 0, true))
      end

      def replay_after_conflict
        placement = Marketing::FeaturedPlacement.find_by(id: placement_id)
        return failure(error(:placement_not_found, status: :not_found)) unless placement

        key = Core::IdempotencyKey.new(raw_idempotency_key)
        audit = Core::AuditLog.find_by(audit_key: audit_key(idempotency_digest(key, placement)))
        return failure(error(:idempotency_conflict, status: :conflict)) unless audit

        replay_result(placement, audit, request_digest: request_digest(placement))
      end

      def error(key, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.#{key}"), code: key.to_s, status:, errors:
        )
      end
    end
  end
end
