# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Completes a paid gift under order/event/gift locks, then issues the ticket
    # from its paid order item while Ticketing assigns it to the recipient.
    class Claim < Core::BaseService
      Result = Data.define(:gift_purchase, :registration, :ticket)

      class Abort < Core::Error
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def initialize(gift_purchase_id:, token:, actor: nil, submission:, idempotency_key:, at: Time.current)
        @gift_purchase_id = gift_purchase_id
        @token = token.to_s
        @actor = actor
        @submission = submission
        @raw_idempotency_key = idempotency_key
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(error(:gift_invalid, :not_found)) if @initialization_error || @token.blank?

        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        initial_gift = find_gift
        return failure(error(:gift_invalid, :not_found)) unless token_matches?(initial_gift)

        request_digest = request_digest_for(initial_gift, key)
        audit_key = claim_audit_key(initial_gift, key)
        replay = replay_result(initial_gift, audit_key:, request_digest:)
        return replay if replay

        result = nil
        ActiveRecord::Base.transaction do
          order_id = Orders::OrderItem.where(id: initial_gift.order_item_id).pick(:order_id)
          raise ActiveRecord::RecordNotFound unless order_id

          CheckoutLock.acquire_for_order!(order_id:)
          order = Orders::Order.lock.find(order_id)
          event = Events::Event.lock.find(order.event_id)
          # Match CreateItemRefund's source-row order before locking the gift;
          # this serializes ticket issuance against the refund's ticket snapshot.
          order_item = Orders::OrderItem.lock.find(initial_gift.order_item_id)
          raise ActiveRecord::RecordNotFound unless order_item.order_id == order.id
          gift = Orders::GiftPurchase.includes(
            :recipient_user,
            order_item: [ :registration, :event_product ]
          ).lock.find(@gift_purchase_id)
          existing_replay = replay_result(gift, audit_key:, request_digest:)
          if existing_replay
            result = existing_replay
            raise ActiveRecord::Rollback
          end
          registration = gift.order_item.registration
          invalid = validate(gift:, order:, event:, registration:)
          if invalid
            result = failure(invalid)
            raise ActiveRecord::Rollback
          end

          recipient = gift.recipient_user
          completion = Ticketing::Registrations::CompleteGift.call(
            registration:,
            actor: recipient,
            submission: recipient_submission(registration),
            idempotency_key: "gift-completion-#{gift.id}-#{key.digest}",
            at: @at
          )
          if completion.failure?
            result = failure(completion.error)
            raise ActiveRecord::Rollback
          end

          issued = issue_ticket(order_item: gift.order_item, event:)
          if issued.failure?
            result = failure(issued.error)
            raise ActiveRecord::Rollback
          end

          ticket = issued.value
          ticket.reload

          has_pending = pending_consents?(registration)
          if has_pending
            previous_status = gift.status
            gift.update!(status: "pending_recipient_consent")
            record_claim_step!(gift, recipient, key, audit_key, request_digest, "pending_recipient_consent", previous_status)
          else
            previous_status = gift.status
            gift.update!(status: "claimed", claimed_at: @at)
            record_claim_step!(gift, recipient, key, audit_key, request_digest, "claimed", previous_status)
          end

          result = success(Result.new(gift_purchase: gift.reload, registration: completion.value, ticket:))
        end
        result
      rescue Abort => exception
        failure(exception.business_error)
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error(:gift_invalid, :not_found))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:gift_claim_failed, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      def find_gift
        Orders::GiftPurchase.includes(:recipient_user, order_item: [ :registration, :order ]).find(@gift_purchase_id)
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def token_matches?(gift)
        return false unless gift && gift.token_digest.present?

        expected = Orders::GiftPurchase.token_digest_for(token: @token)
        ActiveSupport::SecurityUtils.secure_compare(gift.token_digest, expected)
      end

      def validate(gift:, order:, event:, registration:)
        return error(:gift_invalid, :not_found) unless token_matches?(gift)
        return error(:gift_revoked, :gone) if gift.status == "revoked"
        return error(:gift_expired, :gone) if gift.status == "expired" || gift.expires_at <= @at
        return error(:gift_already_claimed, :conflict) if gift.status == "claimed"
        return error(:gift_not_ready, :conflict) unless gift.status.in?(%w[ready pending_recipient_consent])
        return error(:gift_not_ready, :conflict) unless order.status == "fulfilled" && order.paid?
        return error(:event_cancelled, :gone) if event.status == "cancelled"
        return error(:gift_order_not_fulfilled, :conflict) unless
          gift.order_item.fulfilled? && gift.order_item.registration_id == registration&.id
        return error(:gift_recipient_mismatch, :forbidden) unless
          registration&.user_id == gift.recipient_user_id
        return error(:gift_registration_not_pending, :conflict) unless
          registration.status == "gift_pending_claim" ||
          (gift.status == "pending_recipient_consent" && registration.status == "confirmed")
        return error(:gift_recipient_authentication_required, :unauthorized) if
          recipient_requires_authentication?(gift.recipient_user)
        return error(:gift_recipient_mismatch, :forbidden) if @actor && @actor.id != gift.recipient_user_id
        return error(:gift_refund_in_progress, :conflict) if refund_in_progress?(gift.order_item_id)

        nil
      end

      def refund_in_progress?(order_item_id)
        Orders::RefundItem.joins(:refund).where(order_item_id:)
          .where(orders_refunds: { status: Orders::Refund::OUTSTANDING_STATUSES }).exists?
      end

      def recipient_requires_authentication?(recipient)
        @actor.nil? && (recipient.verified_at.present? || recipient.password_digest.present?)
      end

      def recipient_submission(registration)
        submitted = @submission.respond_to?(:to_h) ? @submission.to_h.deep_symbolize_keys : {}
        Ticketing::RegistrationSubmission.new(
          package_quantity: registration.package_quantity,
          selected_event_date_id: registration.selected_event_date_id,
          answers: submitted[:answers],
          consents: submitted[:consents]
        )
      end

      def issue_ticket(order_item:, event:)
        Ticketing::Packages::Issue.call(
          order_item:,
          unit_number: 1,
          event:
        )
      end

      def pending_consents?(registration)
        Ticketing::RegistrationConsentRequirement.where(
          registration_id: registration.id,
          required: true,
          status: "pending"
        ).exists?
      end

      def request_digest_for(gift, key)
        submitted = @submission.respond_to?(:to_h) ? @submission.to_h.deep_symbolize_keys : {}
        form_digest = Core::KeyedDigest.digest(
          namespace: "orders-gift-purchase-form-input:#{gift.id}",
          value: ActiveSupport::JSON.encode(canonical(submitted.slice(:answers, :consents)))
        )
        Core::KeyedDigest.digest(
          namespace: "orders-gift-purchase-claim:#{gift.id}",
          value: [ gift.id, gift.token_digest, @actor&.id || gift.recipient_user_id, key.digest, form_digest ].join(":")
        )
      end

      def claim_audit_key(gift, key)
        "orders-gift-purchase-claimed-#{gift.id}-#{key.digest}"
      end

      def replay_result(gift, audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        if audit
          return failure(error(:idempotency_conflict, :conflict)) unless
            audit.metadata["request_digest"] == request_digest

          ticket = Ticketing::Ticket.find_by!(order_item_id: gift.order_item_id, unit_number: 1)
          return success(Result.new(
            gift_purchase: gift,
            registration: gift.order_item.registration,
            ticket:
          ))
        end
        return failure(error(:gift_already_claimed, :conflict)) if gift.status == "claimed"

        nil
      rescue ActiveRecord::RecordNotFound
        failure(error(:gift_invalid, :not_found))
      end

      def record_claim_step!(gift, recipient, key, audit_key, request_digest, new_status, previous_status = "ready")
        action = new_status == "claimed" ? "orders.gift_purchase.claimed" : "orders.gift_purchase.consent_pending"
        result = Core::Audit::Record.call(
          audit_key:,
          action:,
          auditable_type: gift.class.name,
          auditable_id: gift.id,
          actor_type: recipient.class.name,
          actor_id: recipient.id,
          audited_changes: { status: [ previous_status, new_status ] },
          metadata: {
            order_item_id: gift.order_item_id,
            recipient_user_id: recipient.id,
            idempotency_key_digest: key.digest,
            request_digest:
          }
        )
        raise result.error if result.failure?
      end

      def canonical(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical(nested) }
        when Array
          value.map { |nested| canonical(nested) }
        else
          value.as_json
        end
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.#{key}"),
          code: key.to_s,
          status:,
          errors:
        )
      end
    end
  end
end
