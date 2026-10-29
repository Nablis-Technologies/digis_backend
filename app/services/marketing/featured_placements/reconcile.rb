# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # Repairs missed payment transitions and releases expired or elapsed holds.
    class Reconcile < Core::BaseService
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 500
      Result = Data.define(:payments_recovered, :expired, :ineligible_cancelled, :completed)
      Event = Data.define(:payload, :event_type)

      def initialize(limit: DEFAULT_LIMIT, at: Time.current)
        @limit = [ [ limit.to_i, 1 ].max, MAX_LIMIT ].min
        @at = at.to_time.utc
      end

      def call
        payments_recovered = recover_accepted_payments
        expired = expire_pending
        ineligible_cancelled = cancel_ineligible
        completed = complete_elapsed
        success(Result.new(payments_recovered, expired, ineligible_cancelled, completed))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :limit, :at

      def recover_accepted_payments
        placements = Marketing::FeaturedPlacement.where(status: "pending_payment")
          .joins("INNER JOIN orders_billing_purchases ON orders_billing_purchases.source_id = marketing_featured_placements.id " \
            "AND orders_billing_purchases.source_type = 'Marketing::FeaturedPlacement'")
          .joins("INNER JOIN orders_payments ON orders_payments.billing_purchase_id = orders_billing_purchases.id")
          .where(orders_billing_purchases: { status: "paid" })
          .where("orders_payments.status = 'succeeded' AND orders_payments.accepted_at IS NOT NULL")
          .order("marketing_featured_placements.id").distinct.limit(limit).to_a
        purchases_by_source = Orders::BillingPurchase.where(
          source_type: "Marketing::FeaturedPlacement", source_id: placements.map(&:id)
        ).index_by(&:source_id)
        payments_by_purchase = Orders::Payment.where(
          billing_purchase_id: purchases_by_source.values.map(&:id), status: "succeeded"
        ).where.not(accepted_at: nil).order(:attempt_number).to_a.group_by(&:billing_purchase_id)
        count = 0
        placements.each do |placement|
          purchase = purchases_by_source.fetch(placement.id)
          payment = payments_by_purchase.fetch(purchase.id).last
          result = OutboxHandlers::BillingPaymentAccepted.call(
            event: Event.new(
              payload: {
                "source_type" => purchase.source_type, "source_id" => placement.id,
                "billing_purchase_id" => purchase.id, "payment_id" => payment.id
              },
              event_type: "orders.billing_payment.accepted"
            ), at:
          )
          raise result.error if result.failure?
          count += 1
        end
        count
      end

      def expire_pending
        ids = Marketing::FeaturedPlacement.where(status: "pending_payment")
          .joins("INNER JOIN orders_billing_purchases ON orders_billing_purchases.source_id = marketing_featured_placements.id " \
            "AND orders_billing_purchases.source_type = 'Marketing::FeaturedPlacement'")
          .where(orders_billing_purchases: { status: %w[created pending_payment failed cancelled reversed] })
          .where("orders_billing_purchases.expires_at <= ? OR orders_billing_purchases.status IN ('failed','cancelled','reversed')", at)
          .order("marketing_featured_placements.id").limit(limit).pluck("marketing_featured_placements.id")
        ids.count { |id| expire_one(id) }
      end

      def expire_one(placement_id)
        changed = false
        ActiveRecord::Base.transaction do
          placement = Marketing::FeaturedPlacement.find(placement_id)
          Core::Database::AdvisoryLock.acquire!("marketing", "featured_placements", placement.surface)
          event = Events::Event.lock.find(placement.event_id)
          current = Marketing::FeaturedPlacement.lock.find(placement.id)
          next unless current.status == "pending_payment"

          Orders::Payment.where(billing_purchase_id: billing_purchase_id(current)).order(:id).lock.to_a
          purchase = Orders::BillingPurchase.lock.find_by!(source_type: "Marketing::FeaturedPlacement", source_id: current.id)
          next unless (purchase.expires_at <= at || purchase.status.in?(%w[failed cancelled reversed])) &&
            purchase.status.in?(%w[created pending_payment failed cancelled reversed])

          previous = current.status
          current.update!(status: "failed", failure_code: purchase.status == "pending_payment" ? "checkout_expired" : purchase.status)
          purchase.update!(status: "failed") if purchase.status.in?(%w[created pending_payment])
          audit_transition!(current, event:, from: previous, to: "failed", action: "expired")
          changed = true
        end
        changed
      end

      def complete_elapsed
        ids = Marketing::FeaturedPlacement.where(status: %w[scheduled active]).where("ends_at <= ?", at)
          .order(:id).limit(limit).pluck(:id)
        ids.count { |id| complete_one(id) }
      end

      def cancel_ineligible
        placements = Marketing::FeaturedPlacement.where(status: %w[scheduled active])
          .where("ends_at > ?", at).includes(event: :event_dates).order(:id).limit(limit).to_a
        eligible_event_ids = EventEligibility.eligible_event_ids(events: placements.map(&:event).uniq(&:id), at:)
        placements.count do |placement|
          next false if eligible_event_ids.include?(placement.event_id)

          reason_code = placement.event.status == "cancelled" ? "event_cancelled" : "featured_placement_cancelled"
          result = Cancel.call(
            placement:, actor: nil, system: true, reason_code:,
            idempotency_key: "featured-placement-ineligible-#{placement.id}", at:
          )
          raise result.error if result.failure?

          result.value.placement.status == "cancelled"
        end
      end

      def complete_one(placement_id)
        changed = false
        ActiveRecord::Base.transaction do
          placement = Marketing::FeaturedPlacement.find(placement_id)
          Core::Database::AdvisoryLock.acquire!("marketing", "featured_placements", placement.surface)
          event = Events::Event.lock.find(placement.event_id)
          current = Marketing::FeaturedPlacement.lock.find(placement.id)
          next unless current.status.in?(%w[scheduled active]) && current.ends_at <= at

          previous = current.status
          current.update!(status: "completed", completed_at: at)
          audit_transition!(current, event:, from: previous, to: "completed", action: "completed")
          changed = true
        end
        changed
      end

      def billing_purchase_id(placement)
        Orders::BillingPurchase.where(source_type: "Marketing::FeaturedPlacement", source_id: placement.id).pick(:id)
      end

      def audit_transition!(placement, event:, from:, to:, action:)
        result = Core::Audit::Record.call(
          audit_key: "marketing-featured-placement-#{action}-#{placement.id}",
          action: "marketing.featured_placement.#{action}",
          auditable_type: placement.class.name, auditable_id: placement.id,
          audited_changes: { status: [ from, to ] },
          metadata: { event_id: event.id, failure_code: placement.failure_code }.compact
        )
        raise result.error if result.failure?
      end
    end
  end
end
