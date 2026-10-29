# frozen_string_literal: true

module Marketing
  module FeaturedPlacements
    # Reserves one placement and billing purchase atomically, then starts Chapa
    # after the capacity transaction commits.
    class Create < Core::BaseService
      Result = Data.define(:placement, :billing_purchase, :payment, :replayed)

      def initialize(event:, purchaser:, offer_id:, starts_at:, idempotency_key:, at: Time.current)
        @event = event
        @purchaser = purchaser
        @offer_id = offer_id.to_s
        @raw_starts_at = starts_at
        @raw_idempotency_key = idempotency_key
        @at = at.to_time.utc.change(usec: 0)
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(error(:invalid_idempotency_key, status: :bad_request)) if @initialization_error
        return failure(error(:invalid_idempotency_key, status: :bad_request)) unless key
        return failure(error(:purchase_forbidden, status: :forbidden)) unless authorized?

        scheduled_start = normalize_start_time
        request_digest = request_digest_for(scheduled_start)
        reservation = reserve!(scheduled_start:, request_digest:)
        return reservation if reservation.failure?

        placement, billing_purchase, replayed = reservation.value
        if replayed && billing_purchase.paid?
          return recover_accepted_replay(placement:, billing_purchase:)
        end
        return success(replayed_result(placement:, billing_purchase:)) if replayed &&
          (placement.status != "pending_payment" || billing_purchase.closed?)

        payment_result = Orders::StartBillingPaymentAttempt.call(
          billing_purchase:, buyer: purchaser, provider: "chapa", payment_method: "telebirr",
          idempotency_key: payment_idempotency_key(placement), at:
        )
        return fail_checkout!(placement:, billing_purchase:, error: payment_result.error) if payment_result.failure?

        payment = payment_result.value
        return fail_checkout!(placement:, billing_purchase:, payment:) if payment.status == "failed"
        success(Result.new(placement.reload, billing_purchase.reload, payment, replayed))
      rescue ArgumentError, TypeError
        failure(error(:invalid_schedule))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_placement, errors: exception.record.errors.to_hash))
      rescue ActiveRecord::RecordNotUnique
        replay_after_conflict(request_digest:)
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, status: :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :event, :purchaser, :offer_id, :raw_starts_at, :raw_idempotency_key, :at

      def key
        @key ||= Core::IdempotencyKey.new(raw_idempotency_key)
      rescue ArgumentError
        nil
      end

      def authorized?
        return false unless purchaser

        organization = Organizations::Organization.find_by(id: event.organization_id)
        organization && (purchaser.super_admin? || purchaser.has_role_in?(organization, :owner, :admin))
      end

      def normalize_start_time
        parsed = raw_starts_at.respond_to?(:to_time) ? raw_starts_at.to_time : Time.zone.parse(raw_starts_at.to_s)
        raise ArgumentError if parsed.blank?

        Time.at(parsed.to_i).utc
      end

      def request_digest_for(starts_at)
        Core::KeyedDigest.digest(
          namespace: "marketing-featured-placement-create-request",
          value: ActiveSupport::JSON.encode(
            event_id: event.id, purchaser_id: purchaser.id, offer_id:, starts_at: starts_at.iso8601
          )
        )
      end

      def idempotency_digest
        Core::KeyedDigest.digest(
          namespace: "marketing-featured-placement-create/#{event.organization_id}", value: key.to_s
        )
      end

      def reserve!(scheduled_start:, request_digest:)
        outcome = nil
        ActiveRecord::Base.transaction do
          Core::Database::AdvisoryLock.acquire!("marketing", "featured_placements", PlacementOffer::SURFACES.first)
          locked_event = Events::Event.lock.find(event.id)
          unless authorized_for?(locked_event)
            outcome = failure(error(:purchase_forbidden, status: :forbidden))
            next
          end

          existing = Marketing::FeaturedPlacement.find_by(
            organization_id: locked_event.organization_id, idempotency_key_digest: idempotency_digest
          )
          if existing
            outcome = replay_or_conflict(existing, request_digest:)
            next
          end

          quote = Quote.call(event: locked_event, offer: offer_id, starts_at: scheduled_start, at:)
          if quote.failure?
            outcome = failure(quote.error)
            next
          end
          unless quote.value.capacity_available
            outcome = failure(error(
              :capacity_full, status: :conflict,
              meta: { next_available_at: quote.value.next_available_at&.iso8601 }
            ))
            next
          end

          placement = persist_placement!(locked_event, quote.value, request_digest:)
          billing_purchase = persist_billing_purchase!(placement, request_digest:)
          record_audit!(placement, billing_purchase, request_digest:)
          outcome = success([ placement, billing_purchase, false ])
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:event_ineligible))
      end

      def authorized_for?(locked_event)
        organization = Organizations::Organization.find(locked_event.organization_id)
        purchaser.super_admin? || purchaser.has_role_in?(organization, :owner, :admin)
      end

      def replay_or_conflict(placement, request_digest:)
        return failure(error(:idempotency_conflict, status: :conflict)) unless placement.request_digest == request_digest

        billing_purchase = billing_purchase_for(placement)
        return failure(error(:billing_purchase_unavailable, status: :conflict)) unless billing_purchase

        success([ placement, billing_purchase, true ])
      end

      def persist_placement!(locked_event, quote, request_digest:)
        price_digest = Core::KeyedDigest.digest(
          namespace: "marketing-featured-placement-price",
          value: ActiveSupport::JSON.encode(
            offer_id: quote.offer_id, offer_version: quote.offer_version, surface: quote.surface,
            starts_at: quote.starts_at.iso8601, ends_at: quote.ends_at.iso8601,
            daily_rate_minor: quote.daily_rate_minor, amount_minor: quote.amount_minor,
            currency: quote.currency, terms_version: quote.terms_version
          )
        )
        FeaturedPlacement.create!(
          event: locked_event, organization_id: locked_event.organization_id,
          placement_offer_id: quote.offer_id, status: "pending_payment", surface: quote.surface,
          starts_at: quote.starts_at, ends_at: quote.ends_at, duration_seconds: quote.duration_seconds,
          offer_code: quote.offer_code, offer_version: quote.offer_version,
          daily_rate_minor: quote.daily_rate_minor, amount_minor: quote.amount_minor,
          currency: quote.currency, terms_version: quote.terms_version, price_digest:,
          idempotency_key_digest: idempotency_digest, request_digest:
        )
      end

      def persist_billing_purchase!(placement, request_digest:)
        Orders::BillingPurchase.create!(
          organization_id: placement.organization_id, requested_by: purchaser,
          kind: "featured_placement", source_type: "Marketing::FeaturedPlacement", source_id: placement.id,
          currency: placement.currency, amount_minor: placement.amount_minor, price_digest: placement.price_digest,
          status: "pending_payment", idempotency_key_digest: idempotency_digest,
          expires_at: at + 30.minutes
        )
      end

      def record_audit!(placement, billing_purchase, request_digest:)
        audit = Core::Audit::Record.call(
          audit_key: "marketing-featured-placement-create-#{idempotency_digest}",
          action: "marketing.featured_placement.created", auditable_type: placement.class.name,
          auditable_id: placement.id, actor_type: purchaser.class.name, actor_id: purchaser.id,
          audited_changes: { status: [ nil, "pending_payment" ] },
          metadata: { billing_purchase_id: billing_purchase.id, request_digest: }
        )
        raise audit.error if audit.failure?
      end

      def fail_checkout!(placement:, billing_purchase:, error: nil, payment: nil)
        code = error&.code || payment&.failure_code || "provider_payment_failed"
        ActiveRecord::Base.transaction do
          locked_placement = FeaturedPlacement.lock.find(placement.id)
          locked_purchase = Orders::BillingPurchase.lock.find(billing_purchase.id)
          unless terminal?(locked_placement)
            locked_placement.update!(status: "failed", failure_code: code.to_s.first(80))
            locked_purchase.update!(status: "failed") unless locked_purchase.closed?
            audit = Core::Audit::Record.call(
              audit_key: "marketing-featured-placement-payment-failed-#{locked_placement.id}",
              action: "marketing.featured_placement.payment_failed",
              auditable_type: locked_placement.class.name, auditable_id: locked_placement.id,
              actor_type: purchaser.class.name, actor_id: purchaser.id,
              audited_changes: { status: [ "pending_payment", "failed" ] },
              metadata: { billing_purchase_id: locked_purchase.id, failure_code: code.to_s.first(80) }
            )
            raise audit.error if audit.failure?
          end
          locked_placement.reload
        end
        return success(Result.new(placement.reload, billing_purchase.reload, payment, false)) if payment

        failure(error || self.error(:provider_payment_failed))
      end

      def replay_after_conflict(request_digest:)
        placement = FeaturedPlacement.find_by(
          organization_id: event.organization_id, idempotency_key_digest: idempotency_digest
        )
        return failure(error(:idempotency_conflict, status: :conflict)) unless placement

        replay = replay_or_conflict(placement, request_digest:)
        return replay if replay.failure?

        success(replayed_result(placement:, billing_purchase: replay.value[1]))
      end

      def replayed_result(placement:, billing_purchase:)
        payment = Orders::Payment.where(billing_purchase_id: billing_purchase.id).order(:attempt_number).last
        Result.new(placement, billing_purchase, payment, true)
      end

      def recover_accepted_replay(placement:, billing_purchase:)
        payment = Orders::Payment.where(billing_purchase_id: billing_purchase.id)
          .where(status: "succeeded").where.not(accepted_at: nil).order(:attempt_number).last
        return failure(error(:billing_payment_unavailable, status: :conflict)) unless payment

        event = Data.define(:payload, :event_type).new(
          {
            "source_type" => billing_purchase.source_type, "source_id" => placement.id,
            "billing_purchase_id" => billing_purchase.id, "payment_id" => payment.id
          },
          "orders.billing_payment.accepted"
        )
        applied = OutboxHandlers::BillingPaymentAccepted.call(event:)
        return failure(applied.error) if applied.failure?

        success(Result.new(placement.reload, billing_purchase.reload, payment, true))
      end

      def billing_purchase_for(placement)
        Orders::BillingPurchase.find_by(
          source_type: "Marketing::FeaturedPlacement", source_id: placement.id
        )
      end

      def payment_idempotency_key(placement)
        "marketing-featured-placement-payment-#{placement.id}"
      end

      def terminal?(placement)
        placement.status.in?(%w[completed cancelled failed])
      end

      def error(key, status: :unprocessable_entity, errors: nil, meta: nil)
        Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.#{key}"), code: key.to_s, status:, errors:, meta:
        )
      end
    end
  end
end
