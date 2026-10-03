# frozen_string_literal: true

require "test_helper"

module Orders
  module AdmissionSelections
    class CreateTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @event = events_events(:draft_concert)
        @buyer = core_users(:attendee)
        @actor = core_users(:super_admin)
        @quoted_at = Time.current.change(usec: 0)
        create_messaging_policy
        create_checkout_terms
        @event_date = @event.event_dates.create!(
          name: "Admission selection date #{SecureRandom.hex(3)}",
          starts_at: @quoted_at + 1.day,
          ends_at: @quoted_at + 1.day + 2.hours,
          status: "scheduled"
        )
      end

      test "creates one pending order for a mixed free and paid ticket selection" do
        free_product = create_ticket_product(name: "Free GA", etb_minor: 0)
        paid_product = create_ticket_product(name: "Paid VIP", etb_minor: 1_500)

        result = call_selection(
          items: [
            { event_product_id: free_product.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: paid_product.id, quantity: 1, answers: [], consents: [] }
          ],
          key: "mixed-admission-#{SecureRandom.hex(6)}"
        )

        assert_predicate result, :success?, error_detail(result)
        order = result.value.order
        assert_equal "pending_payment", order.status
        assert_equal "ETB", order.charge_currency
        assert_equal 2, order.order_items.count
        assert_equal 2, order.order_items.where.not(registration_id: nil).count
        assert_equal [ 0, 1_500 ], order.order_items.order(:charge_unit_amount_minor).pluck(:charge_unit_amount_minor)
        assert_empty Ticketing::Ticket.where(order_item_id: order.order_items.select(:id))
        assert_empty Orders::Payment.where(order:)
      end

      test "fulfills a zero-total selection without starting a provider payment" do
        free_product = create_ticket_product(
          name: "Currency-specific free admission",
          etb_minor: 0,
          usd_minor: 1_500
        )
        key = "zero-total-admission-#{SecureRandom.hex(6)}"

        result = call_selection(
          items: [ { event_product_id: free_product.id, quantity: 1, answers: [], consents: [] } ],
          currency: "ETB",
          key:
        )

        assert_predicate result, :success?, error_detail(result)
        order = result.value.order
        assert_equal "fulfilled", order.status
        assert_equal 0, order.total_minor
        assert_equal 0, Orders::Payment.where(order:).count
        assert_equal [ "confirmed" ], result.value.registrations.map(&:status)
        assert_equal [ "confirmed" ], Ticketing::Registration
          .where(id: result.value.registrations.map(&:id))
          .pluck(:status)
        registration = result.value.registrations.sole
        confirmation_audits = Core::AuditLog.where(
          action: "ticketing.registration.free_order_confirmed",
          auditable_type: "Ticketing::Registration",
          auditable_id: registration.id
        )
        assert_equal 1, confirmation_audits.count
        assert_equal [ "pending_payment", "confirmed" ], confirmation_audits.sole.audited_changes.fetch("status")
        assert_empty Core::OutboxEvent.where(
          aggregate_type: "Ticketing::Registration",
          aggregate_id: registration.id,
          event_type: "ticketing.registration.issuance_ready"
        )
        outbox = Core::OutboxEvent.find_by!(aggregate: order, event_type: "orders.payment.fulfilled")
        assert_equal "issuing", result.value.next_action

        replay_before_issuance = call_selection(
          items: [ { event_product_id: free_product.id, quantity: 1, answers: [], consents: [] } ],
          currency: "ETB",
          key:
        )
        assert_predicate replay_before_issuance, :success?, error_detail(replay_before_issuance)
        assert_equal "issuing", replay_before_issuance.value.next_action
        assert_equal [ "confirmed" ], replay_before_issuance.value.registrations.map(&:status)
        assert_equal 1, confirmation_audits.count

        dispatch = Core::Outbox::Dispatch.call(event_id: outbox.id)

        assert_predicate dispatch, :success?, dispatch.error&.message
        assert_equal 1, Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count
        replay = call_selection(
          items: [ { event_product_id: free_product.id, quantity: 1, answers: [], consents: [] } ],
          currency: "ETB",
          key:
        )
        assert_predicate replay, :success?, error_detail(replay)
        assert_equal "confirmed", replay.value.next_action
      end

      test "free stream ticket does not consume physical venue capacity" do
        @event_date.update!(venue_capacity: 0)
        product = create_ticket_product(
          name: "Stream only admission", etb_minor: 0, access_type: "stream", date_selection: "choose_one"
        )

        result = call_selection(
          items: [ {
            event_product_id: product.id, quantity: 1, selected_event_date_id: @event_date.id,
            answers: [], consents: []
          } ],
          key: "stream-admission-#{SecureRandom.hex(6)}"
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal "fulfilled", result.value.order.status
        assert_empty Catalog::VenueCapacityReservation.where(
          reservation_group_id: result.value.order.order_items.select(:id)
        )
        assert_equal 0, @event_date.reload.held_venue_count
        assert_equal 0, @event_date.issued_venue_count
      end

      test "confirms every registration in a zero-total multi-product selection" do
        products = [
          create_ticket_product(name: "Free GA #{SecureRandom.hex(3)}", etb_minor: 0),
          create_ticket_product(name: "Free VIP #{SecureRandom.hex(3)}", etb_minor: 0)
        ]
        items = products.map do |product|
          { event_product_id: product.id, quantity: 1, answers: [], consents: [] }
        end

        result = call_selection(items:, key: "zero-total-basket-#{SecureRandom.hex(5)}")

        assert_predicate result, :success?, error_detail(result)
        order = result.value.order
        assert_equal 0, order.total_minor
        assert_equal "fulfilled", order.reload.status
        assert_equal 2, result.value.registrations.size
        assert_equal [ "confirmed", "confirmed" ], result.value.registrations.map(&:status).sort
        assert_equal 2, Ticketing::Registration.where(id: result.value.registrations.map(&:id), status: "confirmed").count

        outbox = Core::OutboxEvent.find_by!(aggregate: order, event_type: "orders.payment.fulfilled")
        dispatch = Core::Outbox::Dispatch.call(event_id: outbox.id)

        assert_predicate dispatch, :success?, dispatch.error&.message
        assert_equal 2, Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count
      end

      test "a valid promotion that reduces the final total to zero uses no-provider fulfillment" do
        product = create_ticket_product(name: "Promotion-free admission", etb_minor: 1_500)
        promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Comped admission",
          type: "percentage",
          percentage_basis_points: 10_000,
          currency: "ETB",
          status: "active",
          per_user_limit: 1
        )
        code = "COMPED100"
        Catalog::PromotionCode.create!(
          promotion:,
          code:,
          code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code:)
        )

        result = call_selection(
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          key: "admission-promotion-zero-#{SecureRandom.hex(4)}",
          promotion_code: code
        )

        assert_predicate result, :success?, error_detail(result)
        order = result.value.order
        assert_equal 0, order.total_minor
        assert_equal 1_500, order.discount_minor
        assert_equal "fulfilled", order.status
        assert_empty Orders::Payment.where(order:)
        assert_equal "issuing", result.value.next_action
      end

      test "uses the paid override when the buyer selects its currency" do
        product = create_ticket_product(
          name: "Currency-specific paid admission",
          etb_minor: 0,
          usd_minor: 1_500
        )
        Catalog::ExchangeRate.create!(
          from_currency: "ETB",
          to_currency: "USD",
          rate: BigDecimal("0.1"),
          effective_from: @quoted_at - 1.day
        )

        result = call_selection(
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          currency: "USD",
          key: "paid-override-admission-#{SecureRandom.hex(6)}"
        )

        assert_predicate result, :success?, error_detail(result)
        order = result.value.order
        assert_equal "pending_payment", order.status
        assert_equal "USD", order.charge_currency
        assert_equal 1_500, order.order_items.sole.charge_unit_amount_minor
      end

      test "replays the original order for the same key and conflicts on changed selection" do
        free_product = create_ticket_product(name: "Replay free", etb_minor: 0)
        key = "admission-selection-replay-#{SecureRandom.hex(6)}"
        items = [ { event_product_id: free_product.id, quantity: 1, answers: [], consents: [] } ]

        assert_idempotent(-> { call_selection(items:, key:) }, counter: -> { Orders::Order.count })
        first = call_selection(items:, key:)
        replay = call_selection(items:, key:)
        conflict = call_selection(
          items: [ { event_product_id: free_product.id, quantity: 2, answers: [], consents: [] } ],
          key:
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.order.id, replay.value.order.id
        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
        assert_equal 1, Orders::Order.where(buyer_user: @buyer, event: @event).count
      end

      test "guest order replay binds the idempotency key to guest contact inputs" do
        product = create_ticket_product(name: "Guest replay admission", etb_minor: 1_500)
        phone = "+251911#{SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")}"
        key = "guest-admission-replay-#{SecureRandom.hex(4)}"
        request = lambda do |full_name: "Guest Buyer", phone_confirmation: true|
          Orders::AdmissionSelections::Create.call(
            event: @event,
            buyer: nil,
            idempotency_key: key,
            selection: {
              items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
              charge_currency: "ETB",
              guest: true,
              phone:,
              phone_confirmation:,
              full_name:,
              quoted_at: @quoted_at
            }
          )
        end

        first = request.call
        replay = request.call
        conflict = request.call(full_name: "Different Guest")
        confirmation_conflict = request.call(phone_confirmation: false)

        assert_predicate first, :success?, error_detail(first)
        assert_predicate replay, :success?, error_detail(replay)
        assert_equal first.value.order.id, replay.value.order.id
        assert_predicate replay.value.guest_order_token, :present?
        assert_equal "idempotency_conflict", conflict.error.code
        assert_equal "idempotency_conflict", confirmation_conflict.error.code
        assert_equal 1, Orders::Order.where(event: @event, buyer_user: first.value.order.buyer_user).count
      end

      test "resolves and applies a promotion code to an admission selection" do
        product = create_ticket_product(name: "Discounted admission", etb_minor: 1_500)
        promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Admission discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          status: "active",
          per_user_limit: 1
        )
        code = "ADMISSION10"
        Catalog::PromotionCode.create!(
          promotion:,
          code:,
          code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code:)
        )

        result = Orders::AdmissionSelections::Create.call(
          event: @event,
          buyer: @buyer,
          idempotency_key: "admission-promotion-#{SecureRandom.hex(4)}",
          selection: {
            items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
            charge_currency: "ETB",
            promotion_code: " admission10 ",
            quoted_at: @quoted_at
          }
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal 150, result.value.order.discount_minor
        assert_equal promotion.id, result.value.order.promotion_redemption.promotion_id
      end

      test "rejects an invalid promotion code without creating registrations or orders" do
        product = create_ticket_product(name: "Admission invalid promotion", etb_minor: 1_500)

        result = Orders::AdmissionSelections::Create.call(
          event: @event,
          buyer: @buyer,
          idempotency_key: "admission-invalid-promotion-#{SecureRandom.hex(4)}",
          selection: {
            items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
            charge_currency: "ETB",
            promotion_code: "NOT-A-REAL-CODE",
            quoted_at: @quoted_at
          }
        )

        assert_predicate result, :failure?
        assert_equal "invalid_promotion_code", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "submits a manual offer for approval without creating an order" do
        product = create_ticket_product(name: "Reviewed admission", etb_minor: 1_500, approval_mode: "manual")

        result = call_selection(
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          key: "manual-admission-#{SecureRandom.hex(6)}"
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal "awaiting_approval", result.value.next_action
        assert_equal "pending_approval", result.value.registration.status
        assert_nil result.value.order
        assert_empty Orders::Order.where(buyer_user: @buyer, event: @event)
      end

      test "creates a zero-total order from an approved manual registration" do
        product = create_ticket_product(
          name: "Approved free admission", etb_minor: 0, approval_mode: "manual"
        )
        request = call_selection(
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          key: "manual-free-request-#{SecureRandom.hex(6)}"
        )
        assert_predicate request, :success?, error_detail(request)
        assert_equal "awaiting_approval", request.value.next_action

        approved = Ticketing::RegistrationDecisions::Approve.call(
          registration: request.value.registration,
          actor: @actor,
          idempotency_key: "manual-free-approve-#{SecureRandom.hex(6)}"
        )
        assert_predicate approved, :success?, approved.error&.message

        checkout = call_selection(
          items: [ {
            event_product_id: product.id,
            registration_id: approved.value.id,
            quantity: 1,
            answers: [],
            consents: []
          } ],
          key: "manual-free-checkout-#{SecureRandom.hex(6)}"
        )

        assert_predicate checkout, :success?, error_detail(checkout)
        assert_equal "fulfilled", checkout.value.order.status
        assert_equal 0, checkout.value.order.total_minor
        assert_equal "issuing", checkout.value.next_action
        assert_equal 0, Orders::Payment.where(order: checkout.value.order).count
      end

      test "transfers the active waitlist offer hold into the checkout reservation" do
        product = create_ticket_product(
          name: "Waitlist checkout admission",
          etb_minor: 1_500,
          inventory_mode: "event_wide",
          capacity: 1,
          waitlist_enabled: true,
          max_packages_per_user: 1
        )
        submitted = Ticketing::Registrations::Submit.call(
          ticket_type: product.ticket_type,
          actor: @buyer,
          phone: @buyer.phone,
          submission: Ticketing::RegistrationSubmission.new(
            package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
          ),
          audience_proof: {},
          idempotency_key: "waitlist-checkout-register-#{SecureRandom.hex(4)}"
        )
        assert_predicate submitted, :success?, submitted.error&.message
        registration = submitted.value.registration
        queued = Ticketing::Waitlist::Enqueue.call(
          registration:, actor: @buyer, idempotency_key: "waitlist-checkout-enqueue-#{SecureRandom.hex(4)}"
        )
        assert_predicate queued, :success?, queued.error&.message
        offered = Ticketing::Waitlist::OfferNext.call(
          ticket_type: product.ticket_type,
          idempotency_key: "waitlist-checkout-offer-#{SecureRandom.hex(4)}"
        )
        assert_predicate offered, :success?, offered.error&.message
        assert_equal "offered", registration.reload.status
        assert_equal 1, product.inventories.find_by!(event_date_id: nil).reload.held_count

        result = call_selection(
          items: [ {
            event_product_id: product.id,
            registration_id: registration.id,
            quantity: 1,
            answers: [],
            consents: []
          } ],
          key: "waitlist-checkout-selection-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal "pending_payment", registration.reload.status
        assert_equal 1, product.inventories.find_by!(event_date_id: nil).reload.held_count
        assert_equal 1, result.value.order.order_items.count
        assert_equal "released", Catalog::InventoryReservation.find_by!(registration_id: registration.id).status
        assert_equal 1, Catalog::InventoryReservation.by_group(result.value.order.order_items.sole.id)
          .where(status: "held").count
        allocation = Ticketing::PurchaseLimitAllocation.find_by!(registration_id: registration.id)
        assert_equal "reserved", allocation.status
        assert_equal result.value.order.expires_at, allocation.expires_at
      end

      test "rejects a manual offer mixed with automatic tickets atomically" do
        manual_product = create_ticket_product(
          name: "Reviewed admission", etb_minor: 1_500, approval_mode: "manual"
        )
        automatic_product = create_ticket_product(name: "Public admission", etb_minor: 0)

        result = call_selection(
          items: [
            { event_product_id: manual_product.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: automatic_product.id, quantity: 1, answers: [], consents: [] }
          ],
          key: "mixed-manual-admission-#{SecureRandom.hex(6)}"
        )

        assert_predicate result, :failure?
        assert_equal "admission_selection_manual_approval_mixed", result.error.code
        assert_empty Ticketing::Registration.where(event: @event, user: @buyer)
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "rejects duplicate product lines before any registration is created" do
        product = create_ticket_product(name: "Duplicate admission", etb_minor: 1_500)
        item = { event_product_id: product.id, quantity: 1, answers: [], consents: [] }

        result = call_selection(
          items: [ item, item ],
          key: "duplicate-admission-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :failure?
        assert_equal "duplicate_product", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "rejects non-positive quantity before any registration is created" do
        product = create_ticket_product(name: "Invalid quantity admission", etb_minor: 1_500)

        result = call_selection(
          items: [ { event_product_id: product.id, quantity: 0, answers: [], consents: [] } ],
          key: "invalid-admission-quantity-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :failure?
        assert_equal "quantity_invalid", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "returns waitlist availability before registration or proof consumption when sold out" do
        product = create_ticket_product(
          name: "Sold-out selectable ticket",
          etb_minor: 1_500,
          audience: "access_code",
          inventory_mode: "event_wide",
          capacity: 1,
          waitlist_enabled: true
        )
        inventory = product.inventories.find_by!(event_date_id: nil)
        inventory.update!(sold_count: 1)
        raw_code = "SOLD-OUT-#{SecureRandom.hex(4)}"
        code = create_access_code(product.ticket_type, raw_code)

        result = call_selection(
          items: [ {
            event_product_id: product.id,
            quantity: 1,
            answers: [],
            consents: [],
            audience_proof: { access_code: raw_code }
          } ],
          key: "sold-out-selection-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal "waitlist_available", result.value.next_action
        assert_equal [ product.id.to_s ], result.value.waitlist_product_ids
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
        assert_equal 0, code.reload.used_count
        assert_equal 0, inventory.reload.held_count
      end

      test "checks a mixed sold-out selection without writing temporary reservations" do
        available_product = create_ticket_product(
          name: "Available line beside sold-out offer",
          etb_minor: 1_000,
          inventory_mode: "event_wide",
          capacity: 1,
          waitlist_enabled: true
        )
        sold_out_product = create_ticket_product(
          name: "Sold-out line beside available offer",
          etb_minor: 1_500,
          inventory_mode: "event_wide",
          capacity: 1,
          waitlist_enabled: true
        )
        sold_out_product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)
        inventory_reservations_before = Catalog::InventoryReservation.count
        venue_reservations_before = Catalog::VenueCapacityReservation.count

        result = call_selection(
          items: [
            { event_product_id: available_product.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: sold_out_product.id, quantity: 1, answers: [], consents: [] }
          ],
          key: "mixed-sold-out-selection-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal "waitlist_available", result.value.next_action
        assert_equal [ sold_out_product.id.to_s ], result.value.waitlist_product_ids
        assert_equal inventory_reservations_before, Catalog::InventoryReservation.count
        assert_equal venue_reservations_before, Catalog::VenueCapacityReservation.count
        assert_equal 0, available_product.inventories.find_by!(event_date_id: nil).reload.held_count
        assert_equal 0, sold_out_product.inventories.find_by!(event_date_id: nil).reload.held_count
        assert_empty Ticketing::Registration.where(ticket_type: [ available_product.ticket_type, sold_out_product.ticket_type ])
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "aggregates shared venue capacity across lines without temporary venue reservations" do
        first_product = create_ticket_product(
          name: "First venue admission",
          etb_minor: 1_000,
          waitlist_enabled: false
        )
        second_product = create_ticket_product(
          name: "Second venue admission",
          etb_minor: 1_500,
          waitlist_enabled: true
        )
        @event_date.update!(venue_capacity: 1)
        inventory_reservations_before = Catalog::InventoryReservation.count
        venue_reservations_before = Catalog::VenueCapacityReservation.count

        result = call_selection(
          items: [
            { event_product_id: first_product.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: second_product.id, quantity: 1, answers: [], consents: [] }
          ],
          key: "shared-venue-capacity-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :success?, error_detail(result)
        assert_equal "waitlist_available", result.value.next_action
        assert_equal [ second_product.id.to_s ], result.value.waitlist_product_ids
        assert_equal inventory_reservations_before, Catalog::InventoryReservation.count
        assert_equal venue_reservations_before, Catalog::VenueCapacityReservation.count
        assert_equal 0, @event_date.reload.held_venue_count
      end

      test "does not offer the waitlist when inventory is misconfigured" do
        product = create_ticket_product(
          name: "Misconfigured waitlist offer",
          etb_minor: 1_000,
          inventory_mode: "event_wide",
          capacity: 1,
          waitlist_enabled: true
        )
        product.inventories.delete_all

        result = call_selection(
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          key: "misconfigured-inventory-#{SecureRandom.hex(4)}"
        )

        assert_predicate result, :failure?
        assert_equal "inventory_not_configured", result.error.code
        assert_equal I18n.t("orders.checkout.errors.inventory_not_configured"), result.error.message
        refute_includes result.error.message, "no inventory configured"
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "admission and reservation sales windows both close at the exact end time" do
        product = create_ticket_product(name: "Cutoff admission", etb_minor: 1_000)
        cutoff = @quoted_at
        product.update!(sales_end_at: cutoff)

        travel_to(cutoff) do
          result = call_selection(
            items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
            key: "admission-cutoff-#{SecureRandom.hex(4)}"
          )

          assert_predicate result, :failure?
          assert_equal "product_unavailable", result.error.code
          assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        end
      end

      test "unknown inventory preflight failures map to a safe validation error" do
        internal_message = "unpublished inventory internals"
        public_error = Create.allocate.send(
          :inventory_preflight_error,
          Core::BusinessError.new(internal_message, code: "future_checker_error", status: :conflict)
        )

        assert_equal "inventory_validation_failed", public_error.code
        assert_equal :unprocessable_entity, public_error.status
        assert_equal I18n.t("orders.checkout.errors.inventory_validation_failed"), public_error.message
        refute_includes public_error.message, internal_message
      end

      test "replays the same waitlist availability after inventory changes" do
        product = create_ticket_product(
          name: "Replay sold-out offer",
          etb_minor: 1_500,
          inventory_mode: "event_wide",
          capacity: 1,
          waitlist_enabled: true
        )
        inventory = product.inventories.find_by!(event_date_id: nil)
        inventory.update!(sold_count: 1)
        key = "replay-sold-out-#{SecureRandom.hex(4)}"
        items = [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ]

        first = call_selection(items:, key:)
        assert_predicate first, :success?, error_detail(first)
        inventory.update!(sold_count: 0)
        replay = call_selection(items:, key:)

        assert_predicate replay, :success?, error_detail(replay)
        assert_equal "waitlist_available", replay.value.next_action
        assert_equal [ product.id.to_s ], replay.value.waitlist_product_ids
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      test "requires purpose-bound OTP proof before committing a guest zero-total selection" do
        product = create_ticket_product(name: "Guest free admission", etb_minor: 0)
        phone = "+251911#{SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")}"
        key = "guest-free-admission-#{SecureRandom.hex(6)}"
        users_before = Core::User.count

        result = Orders::AdmissionSelections::Create.call(
          event: @event,
          buyer: nil,
          idempotency_key: key,
          selection: {
            items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
            charge_currency: "ETB",
            guest: true,
            phone:,
            phone_confirmation: true,
            quoted_at: @quoted_at
          }
        )

        assert_predicate result, :failure?
        assert_equal "phone_verification_required", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event)
        assert_empty Core::User.where(phone: Core::PhoneIdentity::ResolveOrCreate.normalize(phone))
        assert_equal users_before, Core::User.count
      end

      test "rejects a supplied invalid guest OTP even for a paid selection" do
        product = create_ticket_product(name: "Guest paid admission", etb_minor: 1_500)
        phone = "+251911#{SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")}"

        result = Orders::AdmissionSelections::Create.call(
          event: @event,
          buyer: nil,
          idempotency_key: "guest-paid-invalid-otp-#{SecureRandom.hex(6)}",
          selection: {
            items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
            charge_currency: "ETB",
            guest: true,
            phone:,
            phone_confirmation: true,
            verification_token: "not-a-valid-purpose-bound-token",
            quoted_at: @quoted_at
          }
        )

        assert_predicate result, :failure?
        assert_equal "phone_verification_invalid", result.error.code
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event)
      end

      test "rolls back a consumed access code when quote pricing fails" do
        product = create_ticket_product(name: "Gated admission", etb_minor: 1_500, audience: "access_code")
        code = create_access_code(product.ticket_type, "ROLLBACK-#{SecureRandom.hex(4)}")

        result = call_selection(
          items: [
            {
              event_product_id: product.id, quantity: 1, answers: [], consents: [],
              audience_proof: { access_code: code.code }
            }
          ],
          currency: "USD",
          key: "rollback-admission-#{SecureRandom.hex(6)}"
        )

        assert_predicate result, :failure?
        assert_equal "unsupported_currency", result.error.code
        assert_equal 0, code.reload.used_count
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event, buyer_user: @buyer)
      end

      private

      def call_selection(items:, key:, currency: "ETB", promotion_code: nil)
        assert defined?(Orders::AdmissionSelections::Create),
          "expected the admission-selection command (this assertion is the initial RED state)"

        operation = lambda do
          Orders::AdmissionSelections::Create.call(
            event: @event,
            buyer: @buyer,
            idempotency_key: key,
            selection: {
              items:,
              charge_currency: currency,
              promotion_code:,
              quoted_at: @quoted_at
            }
          )
        end

        # Each selected ticket has its own registration and hold lock workflow;
        # strict loading remains enabled, while Prosopite scanning is reserved
        # for read paths rather than these intentional per-line writes.
        ENV["N_PLUS_ONE"] == "1" ? Prosopite.pause(&operation) : operation.call
      end

      def error_detail(result)
        return unless result.failure?

        "#{result.error.code}: #{result.error.message}"
      end

      def create_ticket_product(
        name:, etb_minor:, usd_minor: nil, approval_mode: "automatic", audience: "public",
        inventory_mode: "unlimited", capacity: nil, waitlist_enabled: false,
        max_packages_per_user: nil, access_type: "venue", date_selection: "fixed"
      )
        product_result = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name:, type: "ticket" },
          ticket_type_attributes: {
            audience:, approval_mode:, date_selection:,
            admissions_per_unit: 1, waitlist_enabled:, max_packages_per_user:
          },
          price_attributes: {
            type: "base", currency: "ETB", amount_minor: etb_minor, active_from: @quoted_at - 1.minute
          },
          inventory_configuration: { mode: inventory_mode, capacity: }
        )
        assert_predicate product_result, :success?, product_result.error&.message
        product = product_result.value
        access_attributes = { event_date: @event_date, type: access_type }
        access_attributes[:required_access_protection] = "public" if access_type == "stream"
        product.product_accesses.create!(access_attributes)
        product.prices.create!(
          type: "override", currency: "USD", amount_minor: usd_minor, active_from: @quoted_at - 1.minute
        ) if usd_minor
        activation = Catalog::Products::Activate.call(product:, actor: @actor)
        assert_predicate activation, :success?, activation.error&.message
        activation.value
      end

      def create_access_code(ticket_type, raw_code)
        Ticketing::AccessCode.create!(
          ticket_type:,
          code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: raw_code),
          max_uses: 1,
          used_count: 0,
          max_quantity_per_use: 1,
          active: true,
          code: raw_code
        )
      end

      def create_checkout_terms
        schedule = create_schedule(
          code: "admission_selection_#{SecureRandom.hex(5)}",
          schedule_type: "platform_default"
        )
        version = create_version(schedule, effective_from: @quoted_at - 1.day)
        create_component(
          version,
          component_type: "platform_commission",
          calculation_type: "explicit_zero",
          charged_to: "organizer",
          funded_by: "organizer",
          basis_type: nil,
          rate_bps: nil,
          label: "Platform commission"
        )
        create_component(
          version,
          component_type: "buyer_service_fee",
          calculation_type: "explicit_zero",
          charged_to: "buyer",
          funded_by: "buyer",
          basis_type: nil,
          rate_bps: nil,
          label: "Buyer service fee"
        )
        create_component(
          version,
          component_type: "processing_cost_recovery",
          calculation_type: "explicit_zero",
          charged_to: "buyer",
          funded_by: "buyer",
          basis_type: nil,
          rate_bps: nil,
          label: "Processing cost recovery"
        )
        sync_definition_digest(version)
        version.update!(status: "active", activated_by: @actor, activated_at: @quoted_at - 1.day)
      end
    end

    class CreateWaitlistConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @event = events_events(:ready_listing)
        @buyer = core_users(:attendee)
        manager = core_users(:super_admin)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: manager,
          product_attributes: { name: "Concurrent admission offer #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, waitlist_enabled: true
          },
          price_attributes: { currency: "ETB", amount_minor: 1_000, active_from: Time.current },
          inventory_configuration: { mode: "event_wide", capacity: 1 }
        ).value
        assert_predicate Catalog::Products::Activate.call(product:, actor: manager), :success?
        @product = product.reload
        @ticket_type = @product.ticket_type
        @product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)
        @registration = Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @buyer,
          created_by: @buyer,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "waitlisted",
          waitlisted_at: Time.current,
          approved_at: Time.current,
          submitted_at: Time.current
        )
      end

      teardown do
        Catalog::InventoryReservation.where(registration_id: @registration&.id).delete_all
        Catalog::VenueCapacityReservation.where(registration_id: @registration&.id).delete_all
        Ticketing::Registration.where(id: @registration&.id).delete_all
        Core::AuditLog.where(auditable_id: [ @registration&.id, @product&.id ]).delete_all
        Core::OutboxEvent.where(aggregate_id: [ @registration&.id, @product&.id ]).delete_all
        Catalog::ProductInventory.where(event_product_id: @product&.id).delete_all
        Catalog::ProductAccess.where(event_product_id: @product&.id).delete_all
        Catalog::ProductPrice.where(event_product_id: @product&.id).delete_all
        Ticketing::TicketType.where(id: @ticket_type&.id).delete_all
        Catalog::EventProduct.where(id: @product&.id).delete_all
      end

      test "waitlist offer work and admission inventory preflight serialize on the ticket type" do
        race = run_database_race do |index|
          if index.zero?
            Ticketing::Waitlist::OfferNext.call(
              ticket_type: Ticketing::TicketType.find(@ticket_type.id),
              idempotency_key: "offer-vs-selection-#{SecureRandom.hex(4)}"
            )
          else
            Orders::AdmissionSelections::Create.call(
              event: Events::Event.find(@event.id),
              buyer: Core::User.find(@buyer.id),
              idempotency_key: "selection-vs-offer-#{SecureRandom.hex(4)}",
              selection: {
                items: [ { event_product_id: @product.id, quantity: 1, answers: [], consents: [] } ],
                charge_currency: "ETB"
              }
            )
          end
        end

        assert_empty race.errors, race.errors.inspect
        assert race.results.all?(&:success?)
        assert_equal "waitlisted", Ticketing::Registration.find(@registration.id).status
        assert_equal 1, Catalog::ProductInventory.where(event_product_id: @product.id).sole.sold_count
        assert_equal 0, Catalog::ProductInventory.where(event_product_id: @product.id).sole.held_count
        assert_equal 0, Catalog::InventoryReservation.where(
          product_inventory_id: Catalog::ProductInventory.where(event_product_id: @product.id).select(:id),
          status: %w[held processing]
        ).count
      end
    end
  end
end
