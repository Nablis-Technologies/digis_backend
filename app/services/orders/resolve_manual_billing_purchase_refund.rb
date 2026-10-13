# frozen_string_literal: true

module Orders
  # Records an authorized operator's attestation that a manual billing refund
  # was externally completed; it never calls the provider.
  class ResolveManualBillingPurchaseRefund < Core::BaseService
    Result = Data.define(:refund, :replayed)
    PERMISSION = "orders.billing_refund.resolve_manual"
    EVIDENCE_REFERENCE = /\A[A-Za-z0-9._:\/-]{1,120}\z/

    def initialize(refund:, actor:, reason:, evidence_reference:, idempotency_key:, at: Time.current)
      @refund_id = refund.id
      @actor = actor
      @reason = reason.to_s.strip
      @evidence_reference = evidence_reference.to_s.strip
      @raw_idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      key = Core::IdempotencyKey.new(raw_idempotency_key)
      return failure(error(:manual_resolution_forbidden, status: :forbidden)) unless authorized?
      return failure(error(:manual_resolution_invalid)) unless valid_inputs?

      payment_id = Orders::Refund.where(id: refund_id).pick(:payment_id)
      return failure(error(:refund_not_found, status: :not_found)) unless payment_id
      @payment_id = payment_id

      result = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(payment_id)
        purchase = Orders::BillingPurchase.lock.find(payment.billing_purchase_id)
        refund = Orders::Refund.lock.find(refund_id)
        command_digest = idempotency_digest(key)
        request_digest = request_digest_for(purchase)
        existing_audit = Core::AuditLog.find_by(audit_key: audit_key(command_digest))
        if existing_audit
          next replay_existing(refund, existing_audit, request_digest:)
        end
        unless refund.type == "billing_purchase_refund" && refund.status == "manual_review" &&
            refund.billing_purchase_id == purchase.id && purchase.source_type.in?(Orders::BillingPurchase::SOURCE_TYPES)
          next failure(error(:refund_not_in_manual_review, status: :conflict))
        end

        refund.update!(
          status: "succeeded", manual_resolved_by: actor, manual_resolution_reason: reason,
          manual_evidence_reference: evidence_reference, manual_resolved_at: at,
          pending_reason: nil, next_retry_at: nil
        )
        record_audit!(refund, payment, purchase, command_digest:, request_digest:)
        publish_succeeded!(refund, payment, purchase)
        success(Result.new(refund, false))
      end
      result
    rescue ArgumentError
      failure(error(:invalid_idempotency_key, status: :bad_request))
    rescue ActiveRecord::RecordNotFound
      failure(error(:refund_not_found, status: :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:manual_resolution_invalid, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      retry_manual_resolution
    rescue Core::Audit::Record::ReplayConflict
      failure(error(:idempotency_conflict, status: :conflict))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :refund_id, :payment_id, :actor, :reason, :evidence_reference, :raw_idempotency_key, :at

    def authorized?
      actor&.super_admin? || actor&.has_permission?(PERMISSION) == true
    end

    def valid_inputs?
      reason.length.between?(10, 255) && evidence_reference.match?(EVIDENCE_REFERENCE)
    end

    def idempotency_digest(key = Core::IdempotencyKey.new(raw_idempotency_key))
      Core::KeyedDigest.digest(
        namespace: "orders-manual-billing-refund-resolution/#{refund_id}/#{actor.id}", value: key.to_s
      )
    end

    def audit_key(digest)
      "orders-manual-billing-refund-resolution-#{digest}"
    end

    def request_digest_for(purchase)
      Core::KeyedDigest.digest(
        namespace: "orders-manual-billing-refund-resolution-request",
        value: ActiveSupport::JSON.encode(
          refund_id:, payment_id:,
          reason:, evidence_reference:, actor_id: actor.id
        )
      )
    end

    def replay_existing(refund, audit, request_digest:)
      stored_request = audit.metadata.to_h["request_digest"]
      return failure(error(:idempotency_conflict, status: :conflict)) unless stored_request == request_digest
      return failure(error(:refund_not_in_manual_review, status: :conflict)) unless refund.status == "succeeded"

      success(Result.new(refund, true))
    end

    def record_audit!(refund, payment, purchase, command_digest:, request_digest:)
      result = Core::Audit::Record.call(
        audit_key: audit_key(command_digest), action: "orders.billing_purchase_refund.manually_resolved",
        auditable_type: refund.class.name, auditable_id: refund.id,
        actor_type: actor.class.name, actor_id: actor.id,
        audited_changes: { status: [ "manual_review", "succeeded" ] },
        metadata: {
          payment_id: payment.id, billing_purchase_id: purchase.id,
          reason:, evidence_reference:, request_digest:
        }
      )
      raise result.error if result.failure?
    end

    def publish_succeeded!(refund, payment, purchase)
      result = Core::Outbox::Publish.call(
        topic: "orders", event_type: "orders.refund.succeeded", aggregate: refund,
        payload: {
          refund_id: refund.id, payment_id: payment.id, billing_purchase_id: purchase.id,
          status: "succeeded", refund_type: refund.type, amount_minor: refund.amount_minor,
          currency: refund.currency
        },
        idempotency_key: "orders-refund-succeeded-#{refund.id}"
      )
      raise result.error if result.failure?
    end

    def retry_manual_resolution
      refund = Orders::Refund.find_by(id: refund_id)
      return failure(error(:refund_not_found, status: :not_found)) unless refund

      audit = Core::AuditLog.find_by(audit_key: audit_key(idempotency_digest))
      return failure(error(:idempotency_conflict, status: :conflict)) unless audit

      replay_existing(refund, audit, request_digest: request_digest_for(Orders::BillingPurchase.find(refund.billing_purchase_id)))
    end

    def error(key, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(I18n.t("orders.refunds.errors.#{key}"), code: key.to_s, status:, errors:)
    end
  end
end
