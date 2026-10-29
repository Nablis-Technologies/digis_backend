# frozen_string_literal: true

module Orders
  # Coordinates checkout release before delegating the registration/proof
  # transition to Ticketing, preserving the shared order-first lock sequence.
  class ReleaseBuyerRegistration < Core::BaseService
    class Abort < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.error.message)
      end
    end

    def initialize(registration_id:, buyer:, idempotency_key:, at: Time.current)
      @registration_id = registration_id
      @buyer = buyer
      @idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      Core::IdempotencyKey.new(@idempotency_key)
      return failure(registration_error(:registration_not_owned, status: :forbidden)) unless
        @buyer.is_a?(Core::User)

      identity = Ticketing::Registration.where(id: @registration_id).pick(:user_id, :event_id)
      return failure(registration_error(:registration_not_releasable, status: :not_found)) unless identity
      return failure(registration_error(:registration_not_owned, status: :forbidden)) unless identity.first == @buyer.id

      Ticketing::Registration.transaction do
        CheckoutLock.acquire!(buyer_user_id: @buyer.id, event_id: identity.last)
        orders = lock_linked_orders
        payments = lock_blocking_payments(orders)
        registration = Ticketing::Registration.lock.find(@registration_id)

        abort_with(registration_error(:registration_not_owned, status: :forbidden)) unless
          registration.user_id == @buyer.id
        next success(registration) if registration.status == "cancelled"
        abort_with(registration_error(:registration_not_releasable)) unless registration.pending_payment?
        abort_with(registration_error(:registration_not_releasable)) if orders.any?(&:paid?)
        abort_with(registration_error(:registration_payment_in_progress)) if payments.any?

        release_active_checkout!(orders)
        release_registration_proof!(registration)
      end
    rescue Abort => error
      error.result
    rescue ArgumentError => error
      failure(registration_error(:invalid_idempotency_key, status: :bad_request, message: error.message))
    rescue Core::Error => error
      failure(error)
    rescue ActiveRecord::RecordNotFound
      failure(registration_error(:registration_not_releasable, status: :not_found))
    rescue ActiveRecord::RecordInvalid => error
      failure(Core::BusinessError.new(
        I18n.t("ticketing.registration_workflows.errors.invalid_registration"),
        code: "invalid_registration", status: :conflict, errors: error.record.errors.to_hash
      ))
    end

    private

    def lock_linked_orders
      order_ids = Orders::OrderItem.where(registration_id: @registration_id)
        .order(:order_id)
        .distinct
        .pluck(:order_id)
      Orders::Order.where(id: order_ids).order(:id).lock.to_a
    end

    def lock_blocking_payments(orders)
      Orders::Payment.where(
        order_id: orders.map(&:id), status: Orders::Payment::RELEASE_BLOCKING_STATUSES
      ).order(:id).lock.to_a
    end

    def release_active_checkout!(orders)
      order = orders.find { |candidate| candidate.status.in?(%w[draft pending_payment]) }
      return unless order

      result = Orders::ReleaseCheckout.call_locked(
        order:, reason: "buyer_requested", at: @at, payment_rows_locked: true
      )
      abort_with(result.error) if result.failure?
    end

    def release_registration_proof!(registration)
      result = Ticketing::Registrations::ReleasePending.call(
        registration:,
        buyer: @buyer,
        idempotency_key: @idempotency_key,
        at: @at
      )
      abort_with(result.error) if result.failure?

      success(result.value)
    end

    def abort_with(business_error)
      raise Abort, failure(business_error)
    end

    def registration_error(code, status: :conflict, message: nil)
      Core::BusinessError.new(
        message || I18n.t("ticketing.registration_workflows.errors.#{code}"),
        code: code.to_s,
        status:
      )
    end
  end
end
