# frozen_string_literal: true

require "bigdecimal"

module Ticketing
  module Packages
    # Issues exactly one commercial ticket package unit from a fulfilled order
    # item or confirmed registration. The source row and source/unit unique
    # index provide retry safety; all slots, the initial generation, credential
    # projection, and package-issued outbox event share one transaction.
    class Issue < Core::BaseService
      CURRENCY_MINOR_UNITS = Catalog::Pricing::CurrencyConverter::CURRENCY_MINOR_UNITS
      UNSET = Object.new.freeze

      def initialize(order_item: nil, registration: nil, unit_number:, source: nil, existing_ticket: UNSET,
        reload_ticket: true, issuance_context: nil)
        @order_item = order_item
        @registration = registration
        @source = source
        @existing_ticket = existing_ticket
        @existing_ticket_checked = !existing_ticket.equal?(UNSET)
        @reload_ticket = reload_ticket
        @issuance_context = issuance_context
        @unit_number = Integer(unit_number)
      rescue ArgumentError, TypeError
        @unit_number = nil
      end

      def call
        return failure(issuance_error(:invalid_unit_number, "invalid_ticket_unit", :unprocessable_entity)) unless
          @unit_number&.positive?
        return failure(issuance_error(:source_required, "ticket_source_required", :unprocessable_entity)) unless
          exactly_one_source?

        outcome = nil
        Ticketing::Ticket.transaction do
          source = lock_source
          existing = @existing_ticket_checked ? @existing_ticket : Ticketing::Ticket.find_by(source_key)
          if existing
            outcome = success(existing)
            next
          end

          verification = verify_source(source)
          if verification.failure?
            outcome = verification
            raise ActiveRecord::Rollback
          end

          ticket = Ticketing::Ticket.create!(ticket_attributes(source))
          slots = create_slots!(ticket)
          generation = Ticketing::CredentialGenerations::CreateInitialGroup.call(
            ticket:,
            admission_slots: slots,
            issuance_context:,
            skip_existing_lookup: @source.present?
          )
          if generation.failure?
            outcome = failure(generation.error)
            raise ActiveRecord::Rollback
          end

          publication = publish_issued!(ticket)
          if publication.failure?
            outcome = failure(publication.error)
            raise ActiveRecord::Rollback
          end

          outcome = success(@reload_ticket ? ticket.reload : ticket)
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(issuance_error(:source_not_found, "ticket_source_not_found", :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.issuance_failed"),
            code: "ticket_issuance_failed",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      rescue ActiveRecord::RecordNotUnique
        existing = Ticketing::Ticket.find_by(source_key)
        return success(existing) if existing

        failure(issuance_error(:issuance_conflict, "ticket_issuance_conflict", :conflict))
      end

      private

      attr_reader :issuance_context

      def exactly_one_source?
        @order_item.present? ^ @registration.present?
      end

      def lock_source
        return @source if @source

        if @order_item
          Orders::OrderItem.lock.includes(
            { order: :event },
            { event_product: [ :ticket_type, { product_accesses: :event_date } ] },
            registration: [ :user, :consent_requirements ]
          ).find(@order_item.id)
        else
          Ticketing::Registration.lock.includes(
            :user,
            :consent_requirements,
            ticket_type: { event_product: [ :ticket_type, { product_accesses: :event_date } ] }
          ).find(@registration.id)
        end
      end

      def source_key
        if @order_item
          { order_item_id: @order_item.id, unit_number: @unit_number }
        else
          { registration_id: @registration.id, unit_number: @unit_number }
        end
      end

      def verify_source(source)
        if source.is_a?(Orders::OrderItem)
          verify_order_item(source)
        else
          verify_registration(source)
        end
      end

      def verify_order_item(item)
        return failure(issuance_error(:source_not_fulfillable, "ticket_source_not_fulfillable", :conflict)) unless
          item.fulfilled? && item.order.status == "fulfilled" && @unit_number <= item.quantity
        return failure(issuance_error(:source_type_invalid, "ticket_source_type_invalid", :unprocessable_entity)) unless
          item.type_snapshot == "ticket" && item.event_product.ticket?
        return failure(issuance_error(:product_access_missing, "ticket_product_access_missing", :unprocessable_entity)) if
          item.event_product.product_accesses.empty?

        success(item)
      end

      def verify_registration(registration)
        return failure(issuance_error(:source_not_fulfillable, "ticket_source_not_fulfillable", :conflict)) unless
          registration.confirmed? && @unit_number <= registration.package_quantity
        return failure(issuance_error(:source_type_invalid, "ticket_source_type_invalid", :unprocessable_entity)) unless
          registration.ticket_type.event_product.ticket?
        return failure(issuance_error(:product_access_missing, "ticket_product_access_missing", :unprocessable_entity)) if
          registration.ticket_type.event_product.product_accesses.empty?

        success(registration)
      end

      def ticket_attributes(source)
        if source.is_a?(Orders::OrderItem)
          order = source.order
          {
            event: order.event,
            event_product: source.event_product,
            registration: source.registration,
            order_item: source,
            unit_number: @unit_number,
            admissions_per_unit_snapshot: source.admissions_per_unit_snapshot,
            owner_user: order.buyer_user,
            current_acquisition_type: order.sales_channel == "resale" ? "resale_purchase" : "primary_purchase",
            current_acquisition_order_item: source,
            current_acquisition_product_value_minor: settlement_unit_value(source),
            current_acquisition_currency: order.settlement_currency,
            credential_mode: "group",
            credential_version: 1,
            status: "active",
            issued_at: Time.current
          }
        else
          {
            event: source.event,
            event_product: source.ticket_type.event_product,
            registration: source,
            unit_number: @unit_number,
            admissions_per_unit_snapshot: source.admissions_per_unit_snapshot,
            owner_user: source.user,
            current_acquisition_type: source.source == "organizer_complimentary" ? "complimentary" : "free_registration",
            current_acquisition_product_value_minor: 0,
            current_acquisition_currency: source.event.currency,
            credential_mode: "group",
            credential_version: 1,
            status: "active",
            issued_at: Time.current
          }
        end
      end

      def create_slots!(ticket)
        1.upto(ticket.admissions_per_unit_snapshot).map do |position|
          ticket.admission_slots.create!(position:, assignment_status: "unassigned")
        end
      end

      def publish_issued!(ticket)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.package_issued",
          aggregate: ticket,
          payload: { ticket_id: ticket.id, version: 1 },
          idempotency_key: "ticketing.package-issued:#{ticket.id}:v1"
        )
      end

      def settlement_unit_value(item)
        charge_unit = item.total_minor.to_d / item.quantity
        return charge_unit.round if item.order.charge_currency == item.order.settlement_currency

        from_units = minor_units(item.order.charge_currency)
        to_units = minor_units(item.order.settlement_currency)
        (charge_unit / from_units * item.order.exchange_rate * to_units).round(0, BigDecimal::ROUND_HALF_UP).to_i
      end

      def minor_units(currency)
        CURRENCY_MINOR_UNITS.fetch(currency.to_sym, 100)
      end

      def issuance_error(key, code, status)
        Core::BusinessError.new(
          I18n.t("ticketing.package_issuance.errors.#{key}"), code:, status:
        )
      end
    end
  end
end
