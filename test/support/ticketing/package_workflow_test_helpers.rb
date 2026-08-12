# frozen_string_literal: true

module Ticketing
  module PackageWorkflowTestHelpers
    def setup_package_workflow(admissions_per_unit: 3, delegation_enabled: true, transferable: true)
      @event = events_events(:ready_listing)
      @owner = core_users(:attendee)
      @recipient = core_users(:core_admin)
      @other_user = core_users(:support)
      @manager = core_users(:super_admin)
      @product = create_package_product(admissions_per_unit:, delegation_enabled:, transferable:)
      @registration = create_confirmed_registration
      @ticket = create_issued_ticket
    end

    private

    def create_package_product(admissions_per_unit:, delegation_enabled:, transferable:)
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @manager,
        product_attributes: { name: "Workflow ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public",
          approval_mode: "automatic",
          date_selection: "fixed",
          admissions_per_unit:,
          delegation_enabled:,
          transferable:
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      event_date = @event.event_dates.create!(
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 4.hours,
        status: "scheduled"
      )
      product.product_accesses.create!(event_date:, type: "venue", usage_limit: 1)
      product
    end

    def create_confirmed_registration
      attributes = {
        event: @event,
        ticket_type: @product.ticket_type,
        user: @owner,
        created_by: @owner,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: @product.ticket_type.admissions_per_unit,
        party_size: @product.ticket_type.admissions_per_unit,
        status: "confirmed",
        submitted_at: Time.current,
        confirmed_at: Time.current
      }
      return Ticketing::Registration.create!(attributes.merge(idempotency_request_digest: SecureRandom.hex(32))) if
        Ticketing::Registration.column_names.include?("idempotency_request_digest")

      values = {
        "id" => SecureRandom.uuid,
        "event_id" => @event.id,
        "ticket_type_id" => @product.ticket_type.id,
        "user_id" => @owner.id,
        "created_by_id" => @owner.id,
        "source" => "self_service",
        "identity_digest" => attributes.fetch(:identity_digest),
        "package_quantity" => attributes.fetch(:package_quantity),
        "admissions_per_unit_snapshot" => attributes.fetch(:admissions_per_unit_snapshot),
        "party_size" => attributes.fetch(:party_size),
        "status" => "confirmed",
        "submitted_at" => attributes.fetch(:submitted_at),
        "confirmed_at" => attributes.fetch(:confirmed_at),
        "created_at" => Time.current,
        "updated_at" => Time.current
      }
      Ticketing::Registration.insert_all!([ values ])
      Ticketing::Registration.find(values.fetch("id"))
    end

    def create_issued_ticket
      order_id = SecureRandom.uuid
      order_attributes = {
          id: order_id,
          event_id: @event.id,
          buyer_user_id: @owner.id,
          sales_channel: "online",
          status: "draft",
          charge_currency: "ETB",
          subtotal_minor: 3_000,
          discount_minor: 0,
          subsidy_minor: 0,
          fee_minor: 0,
          tax_minor: 0,
          adjustment_minor: 0,
          total_minor: 3_000,
          settlement_currency: "ETB",
          settlement_total_minor: 3_000,
          exchange_rate: 1,
          exchange_rate_source: "same_currency",
          exchange_rate_expires_at: 10.minutes.from_now,
          expires_at: 10.minutes.from_now,
          idempotency_key_digest: SecureRandom.hex(32),
          creation_request_digest: SecureRandom.hex(32),
          created_at: Time.current,
          updated_at: Time.current
      }
      if Orders::Order.column_names.include?("commercial_signature")
        order = Orders::Order.create!(order_attributes.merge(commercial_signature: "a" * 64))
      else
        Orders::Order.insert_all!([ order_attributes.stringify_keys ])
        order = Orders::Order.find(order_id)
      end
      item = Orders::OrderItem.create!(
        order:,
        event_product: @product,
        registration: @registration,
        name_snapshot: @product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: @product.ticket_type.admissions_per_unit,
        base_currency: "ETB",
        base_unit_amount_minor: 3_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 3_000,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 3_000,
        fulfillment_status: "fulfilled"
      )
      order.update_columns(status: "fulfilled", paid_at: Time.current)

      Ticketing::Packages::Issue.call(order_item: item, unit_number: 1).value
    end

    def activate_delegated_ticket(assignments: { 1 => @recipient, 2 => nil, 3 => nil }, key: "delegate-test")
      Ticketing::Delegations::Activate.call(
        ticket: @ticket,
        actor: @owner,
        assignments:,
        idempotency_key: key
      )
    end

    def credential_at(position)
      @ticket.reload.current_credential_generation.credentials.includes(:admission_slot).find do |credential|
        credential.admission_slot.position == position
      end
    end
  end
end
