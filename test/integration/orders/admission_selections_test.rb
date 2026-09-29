# frozen_string_literal: true

require "test_helper"

module Orders
  class AdmissionSelectionsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Commercial::GovernanceTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update!(status: "published")
      @actor = core_users(:super_admin)
      @quoted_at = Time.current.change(usec: 0)
      @event.event_dates.create!(
        name: "Admission selection date #{SecureRandom.hex(3)}",
        starts_at: @quoted_at + 1.day,
        ends_at: @quoted_at + 1.day + 2.hours,
        status: "scheduled"
      )
      create_messaging_policy
      create_checkout_terms
      @delivered_codes = []
      @previous_payment_adapters = Payments::Providers::Registry.instance_variable_get(:@adapters)&.dup
      @previous_sender = Rails.application.config.x.phone_verification_sender
      Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
        @delivered_codes << { phone:, code:, challenge_id: challenge.id }
      end
    end

    teardown do
      Rails.application.config.x.phone_verification_sender = @previous_sender
      Payments::Providers::Registry.instance_variable_set(:@adapters, @previous_payment_adapters)
    end

    test "admission selection requires an idempotency key" do
      post selection_path,
           params: { admission_selection: { charge_currency: "ETB", items: [] } },
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "invalid selected event date returns a safe validation error" do
      product = create_ticket_product(name: "Choose a date", amount_minor: 1_500, date_selection: "choose_one")
      payload = selection_payload(product)
      invalid_date_id = SecureRandom.uuid
      payload.dig(:admission_selection, :items).first[:selected_event_date_id] = invalid_date_id

      post selection_path,
           params: payload,
           headers: user_headers.merge("Idempotency-Key" => "invalid-admission-date"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "event_date_unavailable", response.parsed_body.fetch("code")
      assert_equal I18n.t("orders.checkout.errors.event_date_unavailable"), response.parsed_body.fetch("error")
      refute_includes response.body, invalid_date_id
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      assert_empty Orders::Order.where(event: @event)
    end

    test "missing inventory returns a safe error instead of waitlist availability" do
      product = create_ticket_product(
        name: "Unconfigured waitlist ticket", amount_minor: 1_500, inventory_mode: "event_wide",
        capacity: 1, waitlist_enabled: true
      )
      product.inventories.delete_all

      post selection_path,
           params: selection_payload(product),
           headers: user_headers.merge("Idempotency-Key" => "missing-admission-inventory"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "inventory_not_configured", response.parsed_body.fetch("code")
      assert_equal I18n.t("orders.checkout.errors.inventory_not_configured"), response.parsed_body.fetch("error")
      refute_includes response.body, "no inventory configured"
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      assert_empty Orders::Order.where(event: @event)
    end

    test "invalid bearer authentication does not downgrade to guest admission" do
      product = create_ticket_product(name: "Public ticket", amount_minor: 1_500)

      post selection_path,
           params: selection_payload(product),
           headers: { "Authorization" => "Bearer definitely-invalid-token", "Idempotency-Key" => "invalid-bearer" },
           as: :json

      assert_response :unauthorized
      assert_equal "authentication_required", response.parsed_body.fetch("code")
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      assert_empty Orders::Order.where(event: @event)
    end

    test "product ids are scoped to the event slug" do
      other_event = events_events(:draft_concert)
      other_event.update!(visibility: "public")
      Core::Review.create!(
        reviewable: other_event.organization,
        context: "verification",
        status: "approved"
      )
      make_publishable(other_event)
      published = Events::Publish.call(
        event: other_event,
        actor: @actor,
        idempotency_key: "publish-cross-event-admission-#{SecureRandom.hex(4)}"
      )
      assert_predicate published, :success?, published.error&.message
      product = create_ticket_product(name: "Wrong-event product", amount_minor: 1_500)

      post "/public/events/#{other_event.slug}/admission_selections",
           params: selection_payload(product),
           headers: user_headers.merge("Idempotency-Key" => "cross-event-admission-product"),
           as: :json

      assert_response :not_found
      assert_equal "product_not_found", response.parsed_body.fetch("code")
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      assert_empty Orders::Order.where(event: other_event)
    end

    test "authenticated buyer receives one order for a mixed free and paid basket" do
      free_product = create_ticket_product(name: "Free GA", amount_minor: 0)
      paid_product = create_ticket_product(name: "Paid VIP", amount_minor: 1_500)
      payload = selection_payload(free_product, paid_product)
      payload[:admission_selection][:items].each do |item|
        item.merge!(unit_amount_minor: 0, total_minor: 0, provider: "fake")
      end

      with_per_item_write_fanout_paused do
        post selection_path,
             params: payload,
             headers: user_headers.merge("Idempotency-Key" => "authenticated-mixed-admission"),
             as: :json
      end

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "checkout_required", data.dig("next_action", "type")
      order_id = data.dig("order", "id")
      order = Orders::Order.find(order_id)
      assert_equal 2, order.order_items.count
      assert_equal [ 0, 1_500 ], order.order_items.order(:charge_unit_amount_minor).pluck(:charge_unit_amount_minor)
      assert_operator order.total_minor, :>, 1_500
      refute_equal 0, order.total_minor
      assert_empty Ticketing::Ticket.where(order_item_id: order.order_items.select(:id))
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "fresh authenticated buyer can check out an access-code admission" do
      buyer = Core::User.create!(
        email: "admission-buyer-#{SecureRandom.hex(4)}@example.test",
        phone: "+2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}",
        verified_at: Time.current,
        password: "password123"
      )
      token = Core::TokenService.issue(Core::TokenService.access_token_payload(buyer))
      product = create_ticket_product(name: "Gated paid admission", amount_minor: 1_500, audience: "access_code")
      raw_code = "COMPOSABLE-#{SecureRandom.hex(4)}".upcase
      created_code = Ticketing::AccessCodes::Create.call(
        ticket_type: product.ticket_type,
        actor: @actor,
        attributes: { code: raw_code, max_uses: 1 },
        idempotency_key: "composable-access-code-#{SecureRandom.hex(4)}"
      )
      assert_predicate created_code, :success?, created_code.error&.message
      payload = selection_payload(product)
      payload.dig(:admission_selection, :items).first[:audience_proof] = {
        access_code: created_code.value.plaintext
      }
      headers = { "Authorization" => "Bearer #{token}", "Idempotency-Key" => "fresh-buyer-gated-admission" }

      post selection_path, params: payload, headers:, as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "checkout_required", data.dig("next_action", "type")
      order_id = data.dig("order", "id")
      registration = Ticketing::Registration.find(data.fetch("registrations").sole.fetch("id"))
      assert_equal buyer.id, registration.user_id
      assert_equal created_code.value.record.id, registration.access_code_id
      assert_equal 1, created_code.value.record.reload.used_count

      post selection_path, params: payload, headers:, as: :json

      assert_response :created
      assert_equal order_id, response.parsed_body.dig("data", "order", "id")
      assert_equal 1, created_code.value.record.reload.used_count

      order = complete_paid_order(
        order_id:,
        headers:,
        idempotency_key: "fresh-buyer-gated-admission-payment"
      )
      assert_equal "confirmed", registration.reload.status
      assert_equal 1, Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count
    end

    test "invitation proof can be redeemed through composable admission selection" do
      product = create_ticket_product(name: "Invited admission", amount_minor: 1_500, audience: "invitation")
      invitation = Ticketing::Invitations::Create.call(
        ticket_type: product.ticket_type,
        actor: @actor,
        attributes: { email: "invited-#{SecureRandom.hex(4)}@example.test", allowed_quantity: 1 },
        idempotency_key: "composable-invitation-#{SecureRandom.hex(4)}"
      )
      assert_predicate invitation, :success?, invitation.error&.message
      payload = selection_payload(product)
      payload.dig(:admission_selection, :items).first[:audience_proof] = {
        invitation_token: invitation.value.token
      }
      headers = user_headers.merge("Idempotency-Key" => "invited-admission-selection")

      post selection_path, params: payload, headers:, as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "checkout_required", data.dig("next_action", "type")
      registration = Ticketing::Registration.find(data.fetch("registrations").sole.fetch("id"))
      assert_equal invitation.value.record.id, registration.invitation_id
      assert_equal "accepted", invitation.value.record.reload.status
      refute_includes response.body, invitation.value.token

      post selection_path, params: payload, headers:, as: :json

      assert_response :created
      assert_equal data.dig("order", "id"), response.parsed_body.dig("data", "order", "id")
      assert_equal "accepted", invitation.value.record.reload.status

      order = complete_paid_order(
        order_id: data.dig("order", "id"),
        headers:,
        idempotency_key: "invited-admission-payment"
      )
      assert_equal "confirmed", registration.reload.status
      assert_equal 1, Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count
    end

    test "mixed free and paid admission lines issue together exactly once after payment" do
      free_product = create_ticket_product(name: "Paid-order free line", amount_minor: 0)
      paid_product = create_ticket_product(name: "Paid-order paid line", amount_minor: 1_500)
      with_per_item_write_fanout_paused do
        post selection_path,
             params: selection_payload(free_product, paid_product),
             headers: user_headers.merge("Idempotency-Key" => "paid-mixed-admission"),
             as: :json
      end
      assert_response :created
      order = Orders::Order.find(response.parsed_body.dig("data", "order", "id"))
      assert_equal "pending_payment", order.status
      assert_empty Ticketing::Ticket.where(order_item_id: order.order_items.select(:id))

      provider = Payments::Providers::FakePaymentProvider.new(
        outcomes: { create: [ Payments::Providers::Result.success(provider_reference: "mixed-admission-payment") ] }
      )
      Payments::Providers::Registry.register("chapa", provider)
      post "/orders/#{order.id}/payment_attempts",
           params: { payment_attempt: { provider: "chapa", payment_method: "telebirr" } },
           headers: user_headers.merge("Idempotency-Key" => "paid-mixed-admission-attempt"),
           as: :json
      assert_response :created
      payment = Orders::Payment.find(response.parsed_body.dig("data", "id"))
      accepted = nil
      with_per_item_write_fanout_paused do
        accepted = Orders::AcceptPayment.call(payment:)
      end
      assert_predicate accepted, :success?, accepted.error&.message

      fulfillment = Core::OutboxEvent.find_by!(aggregate: order, event_type: "orders.payment.fulfilled")
      dispatch = nil
      with_per_item_write_fanout_paused do
        dispatch = Core::Outbox::Dispatch.call(event_id: fulfillment.id)
      end
      assert_predicate dispatch, :success?, dispatch.error&.message
      assert_equal "fulfilled", order.reload.status
      assert_equal 2, Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count

      replay = nil
      with_per_item_write_fanout_paused do
        replay = Core::Outbox::Dispatch.call(event_id: fulfillment.id)
      end
      assert_predicate replay, :success?, replay.error&.message
      assert_equal 2, Ticketing::Ticket.where(order_item_id: order.order_items.select(:id)).count
    end

    test "guest zero-total selection requires OTP and then creates no-provider order" do
      product = create_ticket_product(name: "Guest free admission", amount_minor: 0)
      phone = "+251911000091"

      post selection_path,
           params: selection_payload(product).deep_merge(
             admission_selection: { phone:, phone_confirmation: true }
           ),
           headers: { "Idempotency-Key" => "guest-admission-without-otp" },
           as: :json

      assert_response :unprocessable_entity
      assert_equal "phone_verification_required", response.parsed_body.fetch("code")
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      assert_empty Orders::Order.where(event: @event)

      post otp_path,
           params: selection_payload(product).deep_merge(
             admission_selection: { phone: }
           ),
           headers: { "Idempotency-Key" => "guest-admission-request-otp" },
           as: :json

      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")
      assert_equal "no-store", response.headers.fetch("Cache-Control")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @delivered_codes.sole.fetch(:code) },
           headers: { "Idempotency-Key" => "guest-admission-verify-otp" },
           as: :json

      assert_response :success
      verification_token = response.parsed_body.dig("data", "verification_token")

      post selection_path,
           params: selection_payload(product).deep_merge(
             admission_selection: { phone:, verification_token: }
           ),
           headers: { "Idempotency-Key" => "guest-admission-with-otp" },
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "issuing", data.dig("next_action", "type")
      assert_equal "fulfilled", data.dig("order", "status")
      assert_equal [ "confirmed" ], data.fetch("registrations").map { |registration| registration.fetch("status") }
      order = Orders::Order.find(data.dig("order", "id"))
      assert_equal 0, order.total_minor
      assert_includes %w[paid fulfilled], order.status
      assert_empty Orders::Payment.where(order:)
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    test "guest paid selection returns an order-bound token accepted by the payment endpoint" do
      product = create_ticket_product(name: "Guest paid checkout", amount_minor: 1_500)
      phone = "+251911000093"

      post selection_path,
           params: selection_payload(product).deep_merge(
             admission_selection: { phone:, phone_confirmation: true, full_name: "Guest Buyer" }
           ),
           headers: { "Idempotency-Key" => "guest-paid-admission-selection" },
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "checkout_required", data.dig("next_action", "type")
      order = Orders::Order.find(data.dig("order", "id"))
      token = data.fetch("guest_order_token")
      assert_empty Ticketing::Ticket.where(order_item_id: order.order_items.select(:id))

      provider = Payments::Providers::FakePaymentProvider.new(
        outcomes: { create: [ Payments::Providers::Result.success(provider_reference: "admission-guest-payment") ] }
      )
      Payments::Providers::Registry.register("chapa", provider)

      post "/guest/orders/#{order.id}/payment_attempts",
           params: {
             payment_attempt: {
               phone: "+251911000094",
               order_access_token: token,
               provider: "chapa",
               payment_method: "telebirr"
             }
           },
           headers: { "Idempotency-Key" => "guest-paid-admission-wrong-phone" },
           as: :json
      assert_response :unprocessable_entity
      assert_equal "invalid_guest_order_token", response.parsed_body.fetch("code")
      assert_empty Orders::Payment.where(order:)

      post "/guest/orders/#{order.id}/payment_attempts",
           params: {
             payment_attempt: {
               phone:,
               order_access_token: token,
               provider: "chapa",
               payment_method: "telebirr"
             }
           },
           headers: { "Idempotency-Key" => "guest-paid-admission-payment" },
           as: :json

      assert_response :created
      payment = Orders::Payment.find(response.parsed_body.dig("data", "id"))
      assert_equal order.id, payment.order_id

      accepted = Orders::AcceptPayment.call(payment:)
      assert_predicate accepted, :success?, accepted.error&.message

      post "/guest/payments/#{payment.id}/refresh",
           params: { payment_refresh: { phone:, order_access_token: token } },
           headers: { "Idempotency-Key" => "guest-paid-admission-refresh-pending" },
           as: :json
      assert_response :success
      assert_equal "pending", response.parsed_body.dig("data", "state")

      fulfillment = Core::OutboxEvent.find_by!(aggregate: order, event_type: "orders.payment.fulfilled")
      dispatch = Core::Outbox::Dispatch.call(event_id: fulfillment.id)
      assert_predicate dispatch, :success?, dispatch.error&.message

      post "/guest/payments/#{payment.id}/refresh",
           params: { payment_refresh: { phone:, order_access_token: token } },
           headers: { "Idempotency-Key" => "guest-paid-admission-refresh-ready" },
           as: :json
      assert_response :success
      assert_equal "ready", response.parsed_body.dig("data", "state")
      guest_ticket = response.parsed_body.dig("data", "tickets").sole
      assert_equal order.order_items.sole.registration_id, guest_ticket.fetch("registration_id")
      ticket_view_token = guest_ticket.fetch("ticket_view_token")

      post "/public/ticket_views/#{ticket_view_token}/request_otp",
           params: { phone: },
           headers: { "Idempotency-Key" => "guest-admission-claim-otp" },
           as: :json
      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @delivered_codes.last.fetch(:code) },
           headers: { "Idempotency-Key" => "guest-admission-claim-verify" },
           as: :json
      assert_response :success
      verification_token = response.parsed_body.dig("data", "verification_token")

      post "/registrations/#{guest_ticket.fetch("registration_id")}/claim_guest",
           params: {
             phone:,
             verification_token:,
             password: "password123",
             password_confirmation: "password123"
           },
           headers: { "Idempotency-Key" => "guest-admission-claim" },
           as: :json
      assert_response :success
      assert response.parsed_body.dig("data", "access_token").present?
    end

    test "request OTP refuses paid products without sending an SMS" do
      product = create_ticket_product(name: "Paid admission", amount_minor: 1_500)

      post otp_path,
           params: selection_payload(product).deep_merge(
             admission_selection: { phone: "+251911000092" }
           ),
           headers: { "Idempotency-Key" => "paid-admission-no-otp" },
           as: :json

      assert_response :unprocessable_entity
      assert_equal "phone_verification_not_required", response.parsed_body.fetch("code")
      assert_empty @delivered_codes
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
    end

    test "approved manual registration continues through the public admission selection endpoint" do
      product = create_ticket_product(
        name: "Manual admission", amount_minor: 1_500, approval_mode: "manual"
      )

      post selection_path,
           params: selection_payload(product),
           headers: user_headers.merge("Idempotency-Key" => "manual-admission-application"),
           as: :json
      assert_response :created
      registration_id = response.parsed_body.dig("data", "registration", "id")
      assert_equal "awaiting_approval", response.parsed_body.dig("data", "next_action", "type")

      approved = Ticketing::RegistrationDecisions::Approve.call(
        registration: Ticketing::Registration.find(registration_id),
        actor: @actor,
        idempotency_key: "manual-admission-approve"
      )
      assert_predicate approved, :success?, approved.error&.message

      post selection_path,
           params: {
             admission_selection: {
               charge_currency: "ETB",
               items: [ {
                 event_product_id: product.id,
                 registration_id:,
                 quantity: 1,
                 answers: [],
                 consents: [],
                 audience_proof: {}
               } ]
             }
           },
           headers: user_headers.merge("Idempotency-Key" => "manual-admission-checkout"),
           as: :json

      assert_response :created
      assert_equal "checkout_required", response.parsed_body.dig("data", "next_action", "type")
      assert_equal "pending_payment", Orders::Order.find(response.parsed_body.dig("data", "order", "id")).status
    end

    test "sold-out selection returns per-offer waitlist availability without creating an order" do
      product = create_ticket_product(
        name: "Sold-out waitlist offer",
        amount_minor: 1_500,
        inventory_mode: "event_wide",
        capacity: 1,
        waitlist_enabled: true
      )
      product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)

      post selection_path,
           params: selection_payload(product),
           headers: user_headers.merge("Idempotency-Key" => "sold-out-selection-handoff"),
           as: :json

      assert_response :created
      action = response.parsed_body.dig("data", "next_action")
      assert_equal "waitlist_available", action.fetch("type")
      assert_equal [ product.id ], action.fetch("event_product_ids")
      assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      assert_empty Orders::Order.where(event: @event)
      assert_equal 0, product.inventories.find_by!(event_date_id: nil).reload.held_count
    end

    private

    def selection_path
      "/public/events/#{@event.slug}/admission_selections"
    end

    def otp_path
      "#{selection_path}/request_otp"
    end

    def selection_payload(*products)
      {
        admission_selection: {
          charge_currency: "ETB",
          items: products.map do |product|
            { event_product_id: product.id, quantity: 1, answers: [], consents: [], audience_proof: {} }
          end
        }
      }
    end

    def create_ticket_product(
      name:, amount_minor:, inventory_mode: "unlimited", capacity: nil,
      waitlist_enabled: false, approval_mode: "automatic", date_selection: "fixed", audience: "public"
    )
      result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @actor,
        product_attributes: { name:, type: "ticket" },
        ticket_type_attributes: {
          audience:, approval_mode:, date_selection:,
          admissions_per_unit: 1, waitlist_enabled:
        },
        price_attributes: { type: "base", currency: "ETB", amount_minor:, active_from: 1.minute.ago },
        inventory_configuration: { mode: inventory_mode, capacity: }
      )
      assert_predicate result, :success?, result.error&.message
      event_date = @event.event_dates.find_by(status: "scheduled")
      result.value.product_accesses.create!(event_date:, type: "venue") if event_date
      activated = Catalog::Products::Activate.call(product: result.value, actor: @actor)
      assert_predicate activated, :success?, activated.error&.message
      activated.value
    end

    def complete_paid_order(order_id:, headers:, idempotency_key:)
      Payments::Providers::Registry.register(
        "chapa",
        Payments::Providers::FakePaymentProvider.new(
          outcomes: {
            create: [ Payments::Providers::Result.success(provider_reference: "admission-#{order_id}") ]
          }
        )
      )
      post "/orders/#{order_id}/payment_attempts",
           params: { payment_attempt: { provider: "chapa", payment_method: "telebirr" } },
           headers: headers.merge("Idempotency-Key" => idempotency_key),
           as: :json
      assert_response :created
      payment = Orders::Payment.find(response.parsed_body.dig("data", "id"))

      accepted = with_per_item_write_fanout_paused { Orders::AcceptPayment.call(payment:) }
      assert_predicate accepted, :success?, accepted.error&.message

      order = Orders::Order.find(order_id)
      fulfillment = Core::OutboxEvent.find_by!(aggregate: order, event_type: "orders.payment.fulfilled")
      dispatch = with_per_item_write_fanout_paused { Core::Outbox::Dispatch.call(event_id: fulfillment.id) }
      assert_predicate dispatch, :success?, dispatch.error&.message
      assert_equal "fulfilled", order.reload.status
      order
    end

    def create_checkout_terms
      schedule = create_schedule(
        code: "public_admission_#{SecureRandom.hex(5)}",
        schedule_type: "platform_default"
      )
      version = create_version(schedule, effective_from: @quoted_at - 1.day)
      create_component(version, rate_bps: 750, label: "Platform commission")
      create_component(
        version,
        component_type: "buyer_service_fee",
        calculation_type: "percentage",
        charged_to: "buyer",
        funded_by: "buyer",
        basis_type: "eligible_order_subtotal",
        rate_bps: 100,
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

    def with_per_item_write_fanout_paused
      return yield unless ENV["N_PLUS_ONE"] == "1"

      # Registration, inventory, and purchase-limit commands deliberately lock
      # and write once per selected offer; query fanout is bounded by basket size.
      Prosopite.pause { yield }
    end
  end
end
