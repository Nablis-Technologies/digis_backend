# frozen_string_literal: true

module Orders
  module GiftPurchaseTestHelpers
    def setup_gift_purchase_context(note: "A private gift note", recipient_phone: "0911000178", recipient_email: nil)
      @gift_event = events_events(:ready_listing)
      @event = @gift_event
      @gift_purchaser = core_users(:attendee)
      @gift_phone = recipient_phone
      @gift_email = recipient_email || "gift-recipient-#{recipient_phone.last(4)}@example.test"
      @gift_event_date = @gift_event.event_dates.create!(
        name: "Gift test date #{SecureRandom.hex(3)}",
        starts_at: 3.days.from_now,
        ends_at: 3.days.from_now + 2.hours,
        status: "scheduled"
      )
      product_result = Catalog::Products::CreateDraft.call(
        event: @gift_event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Gift test ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1, waitlist_enabled: false
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 1_500, active_from: 1.minute.ago
        },
        inventory_configuration: { mode: "unlimited" }
      )
      raise product_result.error if product_result.failure?

      @gift_product = product_result.value
      @gift_product.product_accesses.create!(event_date: @gift_event_date, type: "venue")
      activation = Catalog::Products::Activate.call(product: @gift_product, actor: core_users(:super_admin))
      raise activation.error if activation.failure?

      @gift_product = activation.value
      @gift_ticket_type = @gift_product.ticket_type
      @ticket_type = @gift_ticket_type
      intent = Orders::GiftPurchases::Prepare.call(
        ticket_type: @gift_ticket_type,
        purchaser: @gift_purchaser,
        recipient_phone: @gift_phone,
        recipient_email: @gift_email,
        note:,
        package_quantity: 1,
        idempotency_key: "gift-test-registration-#{SecureRandom.hex(5)}"
      )
      raise intent.error if intent.failure?

      @gift_registration = intent.value.registration
      @registration = @gift_registration
      @gift_order = create_fulfilled_gift_order
      @gift_order_item = @gift_order.order_items.sole
      @gift_token = SecureRandom.urlsafe_base64(32)
      @gift_purchase = Orders::GiftPurchase.create!(
        order_item: @gift_order_item,
        recipient_user: intent.value.recipient,
        recipient_phone: intent.value.recipient_phone,
        recipient_phone_digest: intent.value.recipient_phone_digest,
        recipient_email: intent.value.recipient_email,
        recipient_email_digest: intent.value.recipient_email_digest,
        note: intent.value.note,
        token: @gift_token,
        token_digest: Orders::GiftPurchase.token_digest_for(token: @gift_token),
        status: "ready",
        ready_at: Time.current,
        delivery_status: "pending",
        expires_at: intent.value.expires_at
      )
    end

    def create_required_gift_form
      form = Ticketing::RegistrationForm.create!(
        event: @gift_event,
        name: "Gift registration form #{SecureRandom.hex(3)}",
        active: true
      )
      version = form.versions.create!(version: 1, status: "draft")
      question = version.questions.create!(
        key: "attendee_name",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Attendee name",
        required: true,
        position: 0,
        options: [],
        validation_rules: {}
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
      Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: core_users(:super_admin)
      )
      [ form, version, question ]
    end

    private

    def create_fulfilled_gift_order
      now = Time.current
      order = Orders::Order.create!(
        event: @gift_event,
        buyer_user: @gift_purchaser,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 1_500,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 1_500,
        settlement_currency: "ETB",
        settlement_total_minor: 1_500,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_quoted_at: now,
        exchange_rate_expires_at: now + 10.minutes,
        expires_at: now + 10.minutes,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      order.order_items.create!(
        event_product: @gift_product,
        registration: @gift_registration,
        name_snapshot: @gift_product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: @gift_ticket_type.admissions_per_unit,
        base_currency: "ETB",
        base_unit_amount_minor: 1_500,
        charge_currency: "ETB",
        charge_unit_amount_minor: 1_500,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 1_500,
        fulfillment_status: "fulfilled"
      )
      order.update_columns(status: "fulfilled", paid_at: now)
      order
    end
  end
end
