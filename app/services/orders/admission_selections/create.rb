# frozen_string_literal: true

module Orders
  module AdmissionSelections
    # Coordinates registrations and checkout as one buyer-facing selection.
    # Pricing and payment decisions remain with Orders::BuildQuote and
    # Orders::CreateCheckout; Ticketing retains registration and proof rules.
    class Create < Core::BaseService
      Result = Data.define(
        :order, :registration, :registrations, :next_action, :waitlist_product_ids, :guest_order_token
      )

      class Abort < Core::Error
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def initialize(event:, buyer: nil, selection:, idempotency_key:)
        @event = event
        @buyer = buyer
        @selection = selection.to_h.symbolize_keys
        @items = AdmissionSelectionEnvelope.new(items: @selection[:items]).items
        @charge_currency = @selection[:charge_currency].to_s.upcase
        @raw_idempotency_key = idempotency_key
        @guest = @selection[:guest] == true
        @actor = @guest ? nil : buyer
        @phone = @selection[:phone]
        @phone_confirmation = @selection[:phone_confirmation] == true
        @verification_token = @selection[:verification_token]
        @email = @selection[:email]
        @full_name = @selection[:full_name]
        @promotion_code = @selection[:promotion_code]
        @quoted_at = (@selection[:quoted_at] || Time.current).to_time.utc.change(usec: 0)
      rescue NoMethodError, ArgumentError => error
        @initialization_error = error
      end

      def call
        return failure(selection_error("admission_selection_invalid")) if @initialization_error

        prepare_request!
        resolve_promotion!
        result = nil
        ActiveRecord::Base.transaction do
          resolve_guest_buyer!
          lock_selection!
          @request_digest = request_digest
          replay = replay_result
          if replay
            result = success(replay)
            next
          end

          validate_guest_context!
          products = products_by_id
          validate_selection!(products)
          waitlist_product_ids = preflight_inventory!(products)
          if waitlist_product_ids.present?
            record_waitlist_availability!(waitlist_product_ids)
            result = success(waitlist_result(waitlist_product_ids))
            next
          end
          context = command_context
          assembly = RegistrationAssembler.call(context:, products:)
          abort_with(assembly.error) if assembly.failure?
          registrations = assembly.value
          if manual_request_without_checkout?(products, registrations)
            registration = registrations.sole
            record_registration_request!(registration)
            result = success(result_for_registration(registration))
            next
          end

          dispatch = CheckoutDispatcher.call(context:, registrations:)
          abort_with(dispatch.error) if dispatch.failure?
          order = dispatch.value
          record_order_request!(order)
          result = success(result_for_order(order, registrations))
        end
        result
      rescue Abort => error
        error_result(error)
      end

      private

      attr_reader :event, :buyer, :actor, :charge_currency, :idempotency_key,
                  :promotion, :promotion_code, :quoted_at

      def prepare_request!
        @idempotency_key = Core::IdempotencyKey.new(@raw_idempotency_key)
        @normalized_items = @items
        abort_with(selection_error("items_required")) if @normalized_items.empty?
        ids = @normalized_items.map { |item| item.fetch(:event_product_id) }
        abort_with(selection_error("admission_selection_invalid")) if ids.any?(&:blank?)
        abort_with(selection_error("duplicate_product")) unless ids.uniq.length == ids.length
      rescue ArgumentError => error
        abort_with(selection_error("invalid_idempotency_key", status: :bad_request, message: error.message))
      end

      def resolve_promotion!
        result = Orders::PromotionContext.call(event:, raw_code: @promotion_code)
        abort_with(result.error) if result.failure?

        @promotion = result.value.promotion
        @promotion_code = Catalog::PromotionCode.normalize_code(@promotion_code)
      end

      def resolve_guest_buyer!
        return if !@guest && @buyer.is_a?(Core::User)
        abort_with(selection_error("admission_selection_invalid")) unless @guest
        abort_with(registration_error("phone_identity_invalid", status: :bad_request)) if @phone.blank?

        identity = Core::PhoneIdentity::ResolveGuest.call(phone: @phone)
        abort_with(identity.error) if identity.failure?

        @buyer = identity.value.user
      end

      def validate_guest_context!
        return unless @guest

        if @verification_token.present?
          @guest_otp_verified = verify_guest_otp
          abort_with(selection_error("phone_verification_invalid", status: :unprocessable_entity)) unless @guest_otp_verified
        else
          abort_with(registration_error("phone_confirmation_required", status: :bad_request)) unless @phone_confirmation
        end
      end

      def verify_guest_otp
        Core::PhoneVerification::Verify.valid_proof?(
          token: @verification_token,
          phone: @phone,
          user_id: @buyer.id,
          purpose: "guest_admission"
        )
      end

      def lock_selection!
        product_rows = Catalog::EventProduct.where(event_id: event.id, id: product_ids)
          .includes(:ticket_type).to_a
        abort_with(selection_error("product_not_found", status: :not_found)) unless
          product_rows.map { |product| product.id.to_s }.sort == product_ids

        type_ids = product_rows.filter_map { |product| product.ticket_type&.id }.uniq.sort
        Ticketing::TicketType.where(id: type_ids).order(:id).lock.load
        Orders::CheckoutLock.acquire!(buyer_user_id: buyer.id, event_id: event.id)
        locked_event = Events::Event.lock.find(event.id)
        abort_with(selection_error("event_cancelled", status: :conflict)) if locked_event.status == "cancelled"

        @locked_products = Catalog::EventProduct.where(event_id: locked_event.id, id: product_ids)
          .order(:id).lock.includes(:ticket_type, :prices, :product_accesses).to_a.index_by { |product| product.id.to_s }
      rescue ActiveRecord::RecordNotFound
        abort_with(selection_error("product_not_found", status: :not_found))
      end

      def products_by_id
        @locked_products
      end

      def command_context
        Orders::AdmissionSelectionContext.new(
          event:,
          buyer:,
          actor:,
          items: @normalized_items,
          charge_currency:,
          promotion:,
          promotion_code:,
          guest: @guest,
          phone: @phone,
          phone_confirmation: @phone_confirmation,
          guest_otp_verified: @guest_otp_verified,
          email: @email,
          full_name: @full_name,
          quoted_at:,
          idempotency_key:
        )
      end

      def product_ids
        @normalized_items.map { |item| item.fetch(:event_product_id) }.sort
      end

      def validate_selection!(products)
        manual = []
        @normalized_items.each do |item|
          product = products[item.fetch(:event_product_id)]
          abort_with(selection_error("product_not_found", status: :not_found)) unless product
          abort_with(selection_error("product_unavailable", status: :conflict)) unless product.status == "active"
          abort_with(selection_error("product_unavailable", status: :unprocessable_entity)) unless
            product.ticket? && product.ticket_type.present?
          abort_with(selection_error("quantity_invalid")) unless item[:quantity].is_a?(Integer) && item[:quantity].positive?
          abort_with(selection_error("admission_selection_invalid")) unless item[:answers] && item[:consents]
          manual << item if product.ticket_type.approval_mode == "manual"
        end
        abort_with(selection_error("admission_selection_manual_approval_mixed")) if
          manual.any? && @normalized_items.length > 1
      end

      def preflight_inventory!(products)
        lines = @normalized_items.filter_map do |item|
          product = products.fetch(item.fetch(:event_product_id))
          next if new_manual_application?(item, product) || offered_registration?(item, product)

          validate_sales_window!(product)
          inventory_check_line(item, product)
        end
        result = Catalog::Inventory::CheckAvailability.call(lines:)
        abort_with(inventory_preflight_error(result.error)) if result.failure?

        unavailable = result.value.unavailable_product_ids
        unavailable.each do |product_id|
          product = products.fetch(product_id)
          abort_with(selection_error("inventory_unavailable", status: :conflict)) unless
            product.ticket_type.waitlist_enabled?
        end
        unavailable
      end

      def inventory_check_line(item, product)
        date_ids = inventory_date_ids(item, product)
        Catalog::Inventory::Line.new(
          product:,
          event_date_ids: date_ids,
          venue_event_date_ids: date_ids,
          package_quantity: item[:quantity],
          admissions_per_unit: product.ticket_type.admissions_per_unit
        )
      end

      def inventory_date_ids(item, product)
        ticket_type = product.ticket_type
        return [ item[:selected_event_date_id] ].compact if ticket_type.date_selection == "choose_one"

        product.product_accesses
          .select { |access| access.type.in?(%w[venue parking]) }
          .filter_map(&:event_date_id)
      end

      def new_manual_application?(item, product)
        item[:registration_id].blank? && product.ticket_type.approval_mode == "manual"
      end

      def offered_registration?(item, product)
        return false if item[:registration_id].blank?

        Ticketing::Registration.exists?(
          id: item[:registration_id],
          event_id: event.id,
          user_id: buyer.id,
          ticket_type_id: product.ticket_type.id,
          status: "offered"
        )
      end

      def validate_sales_window!(product)
        return if Catalog::Products::SalesWindow.open?(product)

        abort_with(selection_error("product_unavailable", status: :conflict))
      end

      def inventory_preflight_error(error)
        code = error.respond_to?(:code) ? error.code : nil
        key, status = case code
        when "inventory_not_configured", "inventory_mode_unsupported"
          [ "inventory_not_configured", :unprocessable_entity ]
        when "event_date_unavailable", "event_dates_event_mismatch", "venue_dates_required"
          [ "event_date_unavailable", :unprocessable_entity ]
        when "invalid_capacity_request"
          [ "admission_selection_invalid", :unprocessable_entity ]
        else
          [ "inventory_validation_failed", :unprocessable_entity ]
        end
        selection_error(key, status:)
      end

      def waitlist_result(product_ids)
        Result.new(
          order: nil,
          registration: nil,
          registrations: [],
          next_action: "waitlist_available",
          waitlist_product_ids: product_ids,
          guest_order_token: nil
        )
      end

      def manual_request_without_checkout?(products, registrations)
        return false unless @normalized_items.one?

        item = @normalized_items.sole
        product = products.fetch(item.fetch(:event_product_id))
        registrations.sole.status == "pending_approval" ||
          (item[:registration_id].blank? && product.ticket_type.approval_mode == "manual")
      end

      def record_registration_request!(registration)
        record_command_audit!(
          action: "orders.admission_selection.manual_requested",
          auditable: registration,
          audited_changes: { status: [ nil, registration.status ] },
          metadata: { event_id: event.id, registration_id: registration.id }
        )
      end

      def record_order_request!(order)
        record_command_audit!(
          action: "orders.admission_selection.created",
          auditable: order,
          audited_changes: { status: [ nil, order.status ], total_minor: [ nil, order.total_minor ] },
          metadata: { event_id: event.id, order_id: order.id }
        )
      end

      def record_command_audit!(action:, auditable:, audited_changes:, metadata:)
        result = replay_store.record_command!(
          action:,
          auditable:,
          audited_changes:,
          metadata:
        )
        abort_with(result.error) if result.failure?
      end

      def replay_result
        result = replay_store.fetch
        abort_with(result.error) if result.failure?
        receipt = result.value
        return unless receipt

        case receipt.kind
        when :order then result_for_order(receipt.record)
        when :registration then result_for_registration(receipt.record)
        when :waitlist_available then waitlist_result(receipt.waitlist_product_ids)
        else abort_with(selection_error("idempotency_conflict", status: :conflict))
        end
      end

      def record_waitlist_availability!(product_ids)
        result = replay_store.record_waitlist_available!(product_ids:)
        abort_with(result.error) if result.failure?
      end

      def replay_store
        @replay_store ||= ReplayStore.new(
          event:,
          buyer:,
          idempotency_key:,
          request_digest: @request_digest
        )
      end

      def result_for_order(order, registrations = order.order_items.includes(:registration).filter_map(&:registration))
        action = if order.status == "pending_payment"
          "checkout_required"
        elsif order.status.in?(%w[paid fulfilled]) && issued_ticket_count(order) < expected_ticket_count(order)
          "issuing"
        elsif order.status.in?(%w[paid fulfilled])
          "confirmed"
        else
          order.status
        end
        Result.new(
          order:,
          registration: nil,
          registrations:,
          next_action: action,
          waitlist_product_ids: [],
          guest_order_token: guest_order_token_for(order)
        )
      end

      def issued_ticket_count(order)
        Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count
      end

      def expected_ticket_count(order)
        order.order_items.sum(:quantity)
      end

      def result_for_registration(registration)
        Result.new(
          order: nil,
          registration:,
          registrations: [ registration ],
          next_action: Ticketing::RegistrationNextAction.for(registration).type,
          waitlist_product_ids: [],
          guest_order_token: nil
        )
      end

      def guest_order_token_for(order)
        return unless @guest && order.pending_payment? && @phone.present?

        Orders::GuestOrderAccessToken.issue(order:, buyer:, phone: @phone)
      end

      def request_digest
        payload = {
          event_id: event.id,
          buyer_id: buyer.id,
          charge_currency:,
          promotion_id: @promotion&.id,
          promotion_code: @promotion_code,
          guest_identity: guest_identity_digest,
          items: @normalized_items.map(&:to_h)
        }
        Core::KeyedDigest.digest(
          namespace: "orders-admission-selection-request:#{event.id}",
          value: ActiveSupport::JSON.encode(canonical(payload))
        )
      end

      def guest_identity_digest
        return { guest: false } unless @guest

        {
          guest: true,
          phone_confirmation: @phone_confirmation,
          verification_proof_digest: sensitive_digest("verification", @verification_token),
          email_digest: sensitive_digest("email", @email.to_s.strip.downcase),
          full_name_digest: sensitive_digest("full-name", @full_name.to_s.strip)
        }
      end

      def sensitive_digest(kind, value)
        return if value.blank?

        Core::KeyedDigest.digest(
          namespace: "orders/admission-selection/#{event.id}/#{kind}",
          value:
        )
      end

      def canonical(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical(nested) }
        when Array
          value.map { |nested| canonical(nested) }.sort_by { |nested| ActiveSupport::JSON.encode(nested) }
        else
          value.as_json
        end
      end

      def selection_error(key, status: :unprocessable_entity, message: nil)
        Core::BusinessError.new(
          message || I18n.t("orders.checkout.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end

      def registration_error(key, status: :unprocessable_entity)
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end

      def abort_with(business_error)
        raise Abort, business_error
      end

      def error_result(error)
        failure(error.business_error)
      end
    end
  end
end
