# frozen_string_literal: true

module Orders
  module AdmissionSelections
    # Quotes and dispatches the selected registrations as one order. It runs
    # under Create's transaction so registration, inventory, audit, and order
    # effects still commit or roll back together.
    class CheckoutDispatcher < Core::BaseService
      class Abort < Core::Error
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def initialize(context:, registrations:)
        @context = context
        @registrations = registrations
      end

      def call
        quote = build_quote
        require_guest_proof!(quote)
        dispatch_order(quote)
      rescue Abort => error
        failure(error.business_error)
      end

      private

      attr_reader :context, :registrations

      def build_quote
        result = Orders::BuildQuote.call(
          event: context.event,
          buyer: context.buyer,
          items: quote_items,
          charge_currency: context.charge_currency,
          promotion: context.promotion,
          promotion_code: context.promotion_code,
          quoted_at: context.quoted_at
        )
        abort_with(result.error) if result.failure?

        result.value
      end

      def quote_items
        context.items.zip(registrations).map do |item, registration|
          { product_id: item.fetch(:event_product_id), registration_id: registration.id, quantity: item.fetch(:quantity) }
        end
      end

      def require_guest_proof!(quote)
        return unless context.guest && quote.total_minor.zero? && !context.guest_otp_verified

        abort_with(selection_error("phone_verification_required"))
      end

      def dispatch_order(quote)
        result = Orders::CreateCheckout.call(
          quote:,
          event: context.event,
          buyer: context.buyer,
          idempotency_key: order_idempotency_key
        )
        abort_with(result.error) if result.failure?

        success(result.value)
      end

      def order_idempotency_key
        Digest::SHA256.hexdigest(
          "admission-order:#{context.event.id}:#{context.buyer.id}:#{context.idempotency_key.digest}"
        )
      end

      def selection_error(code)
        Core::BusinessError.new(
          I18n.t("orders.checkout.errors.#{code}"),
          code:,
          status: :unprocessable_entity
        )
      end

      def abort_with(business_error)
        raise Abort, business_error
      end
    end
  end
end
