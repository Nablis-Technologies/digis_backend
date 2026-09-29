# frozen_string_literal: true

module Orders
  module AdmissionSelections
    # Preflights the exact server-owned quote without creating registrations,
    # consuming audience proofs, reserving inventory, or creating an order.
    class RequestOtp < Core::BaseService
      Result = Data.define(:challenge)

      def initialize(event:, items:, charge_currency:, phone:, idempotency_key:,
        promotion_code: nil, quoted_at: nil)
        @event = event
        @items = Orders::AdmissionSelectionEnvelope.new(items:).items
        @charge_currency = charge_currency.to_s.upcase
        @phone = phone
        @raw_idempotency_key = idempotency_key
        @promotion_code = promotion_code
        @quoted_at = (quoted_at || Time.current).to_time.utc.change(usec: 0)
      rescue NoMethodError, ArgumentError => error
        @initialization_error = error
      end

      def call
        return failure(selection_error("admission_selection_invalid")) if @initialization_error

        Core::IdempotencyKey.new(@raw_idempotency_key)
        resolve_promotion!
        validate_request!
        buyer = resolve_guest_identity!
        challenge = Core::PhoneVerification::Request.call(
          user: buyer,
          phone: @phone,
          purpose: "guest_admission",
          idempotency_key: @raw_idempotency_key
        )
        return challenge if challenge.failure?

        success(Result.new(challenge: challenge.value))
      rescue Abort => error
        failure(error.business_error)
      rescue ArgumentError => error
        failure(selection_error("invalid_idempotency_key", status: :bad_request, message: error.message))
      end

      private

      class Abort < StandardError
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def validate_request!
        abort_with(selection_error("event_unavailable", status: :not_found)) unless
          Events::Event.publicly_visible.exists?(id: @event.id)
        abort_with(selection_error("items_required")) if items.empty?
        ids = items.map { |item| item.fetch(:event_product_id) }
        abort_with(selection_error("admission_selection_invalid")) if ids.any?(&:blank?)
        abort_with(selection_error("duplicate_product")) unless ids.uniq.length == ids.length

        products = Catalog::EventProduct.where(event_id: @event.id, id: ids)
          .includes(:prices, :ticket_type, product_accesses: :event_date)
          .index_by { |product| product.id.to_s }
        abort_with(selection_error("product_not_found", status: :not_found)) unless products.size == ids.size
        abort_with(selection_error("admission_selection_manual_approval_mixed")) if
          items.size > 1 && products.values.any? { |product| product.ticket_type&.approval_mode == "manual" }

        quote_items = items.map do |item|
          product = products.fetch(item.fetch(:event_product_id))
          validate_line!(item, product)
          date_ids = quote_event_date_ids(item, product)
          {
            product:,
            registration: nil,
            quantity: item.fetch(:quantity),
            event_date_ids: date_ids,
            venue_event_date_ids: date_ids
          }
        end
        quote = Orders::BuildQuote.call(
          event: @event,
          items: quote_items,
          charge_currency: @charge_currency,
          promotion: @promotion,
          promotion_code: @promotion_code,
          quoted_at: @quoted_at,
          require_registrations: false
        )
        abort_with(quote.error) if quote.failure?
        return if quote.value.total_minor.zero?

        abort_with(selection_error("phone_verification_not_required"))
      end

      def validate_line!(item, product)
        ticket_type = product.ticket_type
        abort_with(selection_error("product_unavailable", status: :conflict)) unless
          product.status == "active" && product.ticket? && ticket_type.present?
        quantity = item[:quantity]
        abort_with(selection_error("quantity_invalid")) unless quantity.is_a?(Integer) && quantity.positive?
        abort_with(selection_error("quantity_outside_product_limit")) unless
          product.min_per_order <= quantity && (product.max_per_order.nil? || quantity <= product.max_per_order)
        abort_with(selection_error("admission_selection_invalid")) unless item[:answers] && item[:consents]
        validate_date!(item, product, ticket_type)
        validate_audience!(item, ticket_type)
        validate_form!(item, ticket_type)
      end

      def quote_event_date_ids(item, product)
        ticket_type = product.ticket_type
        return [ item[:selected_event_date_id] ].compact if ticket_type.date_selection == "choose_one"

        product.product_accesses
          .select { |access| access.type.in?(%w[venue parking]) }
          .filter_map(&:event_date_id)
      end

      def resolve_promotion!
        result = Orders::PromotionContext.call(event: @event, raw_code: @promotion_code)
        abort_with(result.error) if result.failure?

        @promotion = result.value.promotion
        @promotion_code = Catalog::PromotionCode.normalize_code(@promotion_code)
      end

      def validate_date!(item, product, ticket_type)
        selected_date_id = item[:selected_event_date_id]
        if ticket_type.date_selection == "choose_one"
          valid = selected_date_id.present? && product.product_accesses.any? do |access|
            access.event_date_id.to_s == selected_date_id && access.event_date&.status == "scheduled"
          end
          abort_with(selection_error("event_dates_required")) unless valid
        elsif selected_date_id.present?
          abort_with(selection_error("admission_selection_invalid"))
        end
      end

      def validate_audience!(item, ticket_type)
        proof = item.fetch(:audience_proof)
        result = Ticketing::Audience::Authorize.call(
          ticket_type:,
          phone: @phone,
          access_code: proof[:access_code],
          invitation: proof[:invitation_token] || proof[:invitation]
        )
        abort_with(result.error) if result.failure?
      end

      def validate_form!(item, ticket_type)
        schema = Ticketing::Forms::ApplicableSchema.call(event: @event, ticket_type:)
        abort_with(schema.error) if schema.failure?
        result = Ticketing::Forms::ValidateSubmission.call(
          schema: schema.value,
          submission: {
            package_quantity: item[:quantity],
            admissions_per_unit: ticket_type.admissions_per_unit,
            selected_event_date_id: item[:selected_event_date_id],
            answers: item[:answers],
            consents: item[:consents]
          }
        )
        abort_with(result.error) if result.failure?
      end

      def resolve_guest_identity!
        result = Core::PhoneIdentity::ResolveGuest.call(phone: @phone)
        abort_with(result.error) if result.failure?

        result.value.user
      end

      def items
        @items
      end

      def selection_error(key, status: :unprocessable_entity, message: nil)
        Core::BusinessError.new(
          message || I18n.t("orders.checkout.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end

      def abort_with(business_error)
        raise Abort, business_error
      end
    end
  end
end
