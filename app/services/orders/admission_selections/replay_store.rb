# frozen_string_literal: true

module Orders
  module AdmissionSelections
    # Persists and resolves command receipts through the authoritative audit
    # writer so response replay is durable without treating audit rows as cache.
    class ReplayStore
      Receipt = Data.define(:kind, :record, :waitlist_product_ids)

      def initialize(event:, buyer:, idempotency_key:, request_digest:)
        @event = event
        @buyer = buyer
        @audit_key = "orders-admission-selection-#{event.id}-#{buyer.id}-#{idempotency_key.digest}"
        @request_digest = request_digest
      end

      def fetch
        audit = Core::AuditLog.find_by(audit_key:)
        return Core::BaseService::Result.success unless audit
        return conflict unless audit.metadata.to_h.stringify_keys["request_digest"] == request_digest

        receipt = receipt_for(audit)
        receipt ? Core::BaseService::Result.success(receipt) : conflict
      rescue ActiveRecord::RecordNotFound, KeyError, NoMethodError, TypeError
        conflict
      end

      def record_command!(action:, auditable:, audited_changes:, metadata:)
        record!(
          action:,
          auditable_type: auditable.class.name,
          auditable_id: auditable.id,
          audited_changes:,
          metadata:
        )
      end

      def record_waitlist_available!(product_ids:)
        record!(
          action: "orders.admission_selection.waitlist_available",
          auditable_type: "Catalog::EventProduct",
          auditable_id: product_ids.first,
          audited_changes: { next_action: [ nil, "waitlist_available" ] },
          metadata: { event_id: event.id, waitlist_product_ids: product_ids }
        )
      end

      private

      attr_reader :event, :buyer, :audit_key, :request_digest

      def receipt_for(audit)
        case audit.auditable_type
        when "Orders::Order"
          Receipt.new(kind: :order, record: Orders::Order.find(audit.auditable_id), waitlist_product_ids: [])
        when "Ticketing::Registration"
          Receipt.new(kind: :registration, record: Ticketing::Registration.find(audit.auditable_id), waitlist_product_ids: [])
        when "Catalog::EventProduct"
          waitlist_receipt(audit)
        end
      end

      def waitlist_receipt(audit)
        return unless audit.action == "orders.admission_selection.waitlist_available"

        raw_product_ids = audit.metadata.to_h.stringify_keys.fetch("waitlist_product_ids")
        return unless raw_product_ids.is_a?(Array)

        product_ids = raw_product_ids.map(&:to_s).freeze
        return if product_ids.empty?

        Receipt.new(kind: :waitlist_available, record: nil, waitlist_product_ids: product_ids)
      end

      def record!(action:, auditable_type:, auditable_id:, audited_changes:, metadata:)
        Core::Audit::Record.call(
          audit_key:,
          action:,
          auditable_type:,
          auditable_id:,
          actor_type: buyer.class.name,
          actor_id: buyer.id,
          audited_changes:,
          metadata: metadata.merge(request_digest:)
        )
      end

      def conflict
        Core::BaseService::Result.failure(
          Core::BusinessError.new(
            I18n.t("orders.checkout.errors.idempotency_conflict"),
            code: "idempotency_conflict",
            status: :conflict
          )
        )
      end
    end
  end
end
