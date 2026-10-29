# frozen_string_literal: true

module Ticketing
  module Waitlist
    # Requests the shared guest-admission OTP only for an eligible sold-out
    # offer; audience proof is checked read-only and never consumed here.
    class RequestOtp < Core::BaseService
      Result = Data.define(:challenge)

      def initialize(event:, ticket_type:, phone:, quantity:, idempotency_key:,
        audience_proof: {}, selected_event_date_id: nil)
        @event = event
        @ticket_type = ticket_type
        @phone = phone
        @quantity = quantity
        @raw_idempotency_key = idempotency_key
        @audience_proof = audience_proof.to_h.symbolize_keys.slice(:access_code, :invitation, :invitation_token)
        @selected_event_date_id = selected_event_date_id
      end

      def call
        Core::IdempotencyKey.new(@raw_idempotency_key)
        product = validated_product
        validate_quantity!(product)
        validate_audience!
        abort_with(waitlist_error("waitlist_not_sold_out")) if available?(product)
        buyer = resolve_guest_identity!
        result = Core::PhoneVerification::Request.call(
          user: buyer,
          phone: @phone,
          purpose: "guest_admission",
          idempotency_key: @raw_idempotency_key
        )
        return result if result.failure?

        success(Result.new(challenge: result.value))
      rescue Abort => error
        failure(error.business_error)
      rescue ArgumentError => error
        failure(waitlist_error("invalid_idempotency_key", status: :bad_request, message: error.message))
      rescue ActiveRecord::RecordNotFound
        failure(waitlist_error("waitlist_product_not_found", status: :not_found))
      end

      private

      class Abort < StandardError
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end

      def validated_product
        product = Catalog::EventProduct.where(
          event_id: @event.id, id: @ticket_type.event_product_id
        ).includes(:prices, :product_accesses, :inventories, :ticket_type).find_by(id: @ticket_type.event_product_id)
        abort_with(waitlist_error("waitlist_product_not_found", status: :not_found)) unless
          Events::Event.publicly_visible.exists?(id: @event.id) && product&.status == "active" &&
          product.ticket? && product.ticket_type&.id == @ticket_type.id && product.ticket_type.waitlist_enabled?
        now = Time.current
        abort_with(waitlist_error("waitlist_product_unavailable")) if
          Catalog::Products::SalesWindow.error_key(product, at: now)
        validate_selected_date!(product)
        product
      end

      def validate_selected_date!(product)
        date_id = @selected_event_date_id
        valid = if @ticket_type.date_selection == "choose_one"
          date_id.present? && product.product_accesses.any? do |access|
            access.event_date_id.to_s == date_id.to_s && access.event_date&.status == "scheduled"
          end
        else
          date_id.blank?
        end
        abort_with(waitlist_error("event_dates_required")) unless valid
      end

      def validate_quantity!(product)
        abort_with(waitlist_error("quantity_invalid")) unless @quantity.is_a?(Integer) && @quantity.positive?
        abort_with(waitlist_error("quantity_outside_product_limit")) unless
          product.min_per_order <= @quantity && (product.max_per_order.nil? || @quantity <= product.max_per_order)
      end

      def validate_audience!
        result = Ticketing::Audience::Authorize.call(
          ticket_type: @ticket_type,
          phone: @phone,
          access_code: @audience_proof[:access_code],
          invitation: @audience_proof[:invitation_token] || @audience_proof[:invitation]
        )
        abort_with(result.error) if result.failure?
      end

      def available?(product)
        dates = selected_event_dates(product)
        inventories = product.inventories.index_by { |inventory| inventory.event_date_id&.to_s }
        inventory_available = case product.inventory_mode
        when "unlimited"
          true
        when "event_wide"
          inventory_available_for?(inventories[nil], @quantity)
        when "per_date"
          dates.present? && dates.all? { |date| inventory_available_for?(inventories[date.id.to_s], @quantity) }
        when "event_wide_and_per_date"
          inventory_available_for?(inventories[nil], @quantity) && dates.present? &&
            dates.all? { |date| inventory_available_for?(inventories[date.id.to_s], @quantity) }
        else
          false
        end
        return false unless inventory_available

        dates.all? do |date|
          date.venue_capacity.blank? ||
            date.held_venue_count + date.issued_venue_count +
              @quantity * @ticket_type.admissions_per_unit <= date.venue_capacity
        end
      end

      def selected_event_dates(product)
        ids = if @ticket_type.date_selection == "choose_one"
          [ @selected_event_date_id ].compact
        else
          product.product_accesses.select { |access| access.type.in?(%w[venue parking]) }
            .map(&:event_date_id).uniq
        end
        Events::EventDate.where(id: ids, event_id: @event.id, status: "scheduled").order(:id).to_a
      end

      def inventory_available_for?(inventory, quantity)
        inventory.present? && inventory.available_quantity >= quantity
      end

      def resolve_guest_identity!
        result = Core::PhoneIdentity::ResolveGuest.call(phone: @phone)
        abort_with(result.error) if result.failure?

        result.value.user
      end

      def waitlist_error(code, status: :unprocessable_entity, message: nil)
        Core::BusinessError.new(
          message || I18n.t("ticketing.registration_workflows.errors.#{code}"),
          code:,
          status:
        )
      end

      def abort_with(business_error)
        raise Abort, business_error
      end
    end
  end
end
