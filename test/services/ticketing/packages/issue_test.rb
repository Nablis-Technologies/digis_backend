# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Packages
    class IssueTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        create_messaging_policy
        @event = events_events(:ready_listing)
        @buyer = core_users(:attendee)
        @manager = core_users(:super_admin)
        @product = create_ticket_product(admissions_per_unit: 3)
        @registration = create_registration
      end

      test "issues one package and complete slot set once" do
        item = create_fulfilled_order_item

        first = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1)
        second = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal first.value.id, second.value.id
        assert_equal [ 1, 2, 3 ], first.value.admission_slots.order(:position).pluck(:position)
        assert_equal "group", first.value.current_credential_generation.mode
        assert_equal "active", first.value.credentials.sole.status
        assert_not_empty first.value.credentials.sole.qr_token
        assert_match(/\A[23456789CFGHJKMNPQRVWX]{8}\z/, first.value.credentials.sole.lookup_code)
        assert_equal 1, Ticketing::AttendeeIndexEntry.where(ticket_id: first.value.id).count
        assert_equal 1, Core::OutboxEvent.where(
          aggregate_id: first.value.id, event_type: "ticketing.package_issued"
        ).count
      end

      test "issues a confirmed registration as a free package" do
        result = Ticketing::Packages::Issue.call(registration: @registration, unit_number: 1)

        assert_predicate result, :success?, result.error&.message
        ticket = result.value
        assert_equal @registration.id, ticket.registration_id
        assert_nil ticket.order_item_id
        assert_equal "free_registration", ticket.current_acquisition_type
        assert_equal 0, ticket.current_acquisition_product_value_minor
        assert_equal @buyer.id, ticket.owner_user_id
      end

      test "issues every missing unit through the registration command" do
        result = Ticketing::Registrations::IssuePackages.call(registration_id: @registration.id)

        assert_predicate result, :success?, result.error&.message
        assert result.value.complete
        assert_equal [ 1 ], result.value.tickets.map(&:unit_number)
      end

      test "leaves the group credential pending when a personal requirement is incomplete" do
        create_pending_personal_requirement

        result = Ticketing::Packages::Issue.call(registration: @registration, unit_number: 1)

        assert_predicate result, :success?, result.error&.message
        credential = result.value.credentials.sole
        assert_equal "pending_requirements", credential.status
        assert_nil credential.qr_token
        assert_nil credential.lookup_code
        assert_empty Ticketing::AttendeeIndexEntry.where(credential_id: credential.id)
      end

      test "rejects an order item before fulfillment" do
        item = create_order_item

        result = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1)

        assert_predicate result, :failure?
        assert_equal "ticket_source_not_fulfillable", result.error.code
        assert_empty Ticketing::Ticket.where(order_item_id: item.id)
      end

      test "does not issue a registration package after event cancellation" do
        @event.update!(status: "cancelled")

        result = Ticketing::Packages::Issue.call(registration: @registration, unit_number: 1)

        assert_predicate result, :failure?
        assert_equal "event_cancelled", result.error.code
        assert_empty Ticketing::Ticket.where(registration_id: @registration.id)
      end

      test "dispatches package delivery through the registered handler" do
        item = create_fulfilled_order_item
        ticket = Ticketing::Packages::Issue.call(order_item: item, unit_number: 1).value
        event = Core::OutboxEvent.find_by!(aggregate_id: ticket.id, event_type: "ticketing.package_issued")

        delivered = nil
        previous_sender = Rails.application.config.x.credential_delivery_sender
        Rails.application.config.x.credential_delivery_sender = lambda do |**details|
          delivered = details
        end

        begin
          dispatch = Core::Outbox::Dispatch.call(event_id: event.id)
        ensure
          Rails.application.config.x.credential_delivery_sender = previous_sender
        end

        assert_predicate dispatch, :success?, dispatch.error&.message
        assert_not_nil event.reload.published_at
        assert_equal(
          { ticket_id: ticket.id, version: 1, idempotency_key: event.idempotency_key },
          delivered
        )
        notification = Messaging::Notification.find_by!(source: ticket, notification_type: "ticket_issued")
        assert_equal ticket.owner_user_id, notification.user_id
      end

      test "replaying the order fulfillment handler does not issue duplicate tickets" do
        item = create_fulfilled_order_item(quantity: 2)
        event = Core::Outbox::Publish.call(
          topic: "orders",
          event_type: "orders.payment.fulfilled",
          aggregate: item.order,
          payload: { order_id: item.order_id, order_item_ids: [ item.id ] },
          idempotency_key: "orders-fulfilled-for-ticketing-#{item.order_id}"
        ).value

        subject = -> { Rails.application.config.x.outbox_handlers.fetch(event.event_type).call(event) }
        assert_idempotent(subject, counter: -> { Ticketing::Ticket.where(order_item_id: item.id).count })

        assert_equal [ 1, 2 ], Ticketing::Ticket.where(order_item_id: item.id).order(:unit_number).pluck(:unit_number)
      end

      test "replaying registration issuance does not issue duplicate tickets" do
        event = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.registration.issuance_ready",
          aggregate: @registration,
          payload: { registration_id: @registration.id },
          idempotency_key: "registration-issuance-ready-#{@registration.id}"
        ).value

        subject = -> { Rails.application.config.x.outbox_handlers.fetch(event.event_type).call(event) }
        assert_idempotent(subject, counter: -> { Ticketing::Ticket.where(registration_id: @registration.id).count })

        assert_equal 1, Ticketing::Ticket.where(registration_id: @registration.id).count
      end

      private

      def create_ticket_product(admissions_per_unit:)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Issue ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public",
            approval_mode: "automatic",
            date_selection: "fixed",
            admissions_per_unit:
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

      def create_registration
        Ticketing::Registration.create!(
          event: @event,
          ticket_type: @product.ticket_type,
          user: @buyer,
          created_by: @buyer,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 3,
          party_size: 3,
          status: "confirmed",
          submitted_at: Time.current,
          confirmed_at: Time.current
        )
      end

      def create_order(quantity: 1)
        total = 3_000 * quantity
        Orders::Order.create!(
          event: @event,
          buyer_user: @buyer,
          sales_channel: "online",
          status: "draft",
          charge_currency: "ETB",
          commercial_signature: "a" * 64,
          subtotal_minor: total,
          discount_minor: 0,
          subsidy_minor: 0,
          fee_minor: 0,
          tax_minor: 0,
          adjustment_minor: 0,
          total_minor: total,
          settlement_currency: "ETB",
          settlement_total_minor: total,
          exchange_rate: 1,
          exchange_rate_source: "same_currency",
          exchange_rate_expires_at: 10.minutes.from_now,
          expires_at: 10.minutes.from_now,
          idempotency_key_digest: SecureRandom.hex(32),
          creation_request_digest: SecureRandom.hex(32)
        )
      end

      def create_order_item(quantity: 1)
        order = create_order(quantity:)
        order.order_items.create!(
          event_product: @product,
          registration: @registration,
          name_snapshot: @product.name,
          type_snapshot: "ticket",
          quantity:,
          admissions_per_unit_snapshot: 3,
          base_currency: "ETB",
          base_unit_amount_minor: 3_000,
          charge_currency: "ETB",
          charge_unit_amount_minor: 3_000,
          exchange_rate: 1,
          discount_minor: 0,
          total_minor: 3_000 * quantity,
          fulfillment_status: "pending"
        )
      end

      def create_fulfilled_order_item(quantity: 1)
        item = create_order_item(quantity:)
        item.order.update_columns(status: "fulfilled", paid_at: Time.current)
        item.update!(fulfillment_status: "fulfilled")
        item.reload
      end

      def create_pending_personal_requirement
        document = Events::ConsentDocument.create!(
          event: @event,
          name: "Personal requirement #{SecureRandom.hex(4)}",
          type: "liability_waiver",
          created_by: @manager
        )
        version = document.versions.create!(
          version: 1,
          title: "Personal terms",
          body: "Personal terms body",
          content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
            type: document.type, title: "Personal terms", body: "Personal terms body"
          ),
          required: true,
          acceptance_scope: "admission_slot",
          status: "draft",
          created_by: @manager
        )
        version.update!(status: "published", published_by: @manager, published_at: Time.current)
        Ticketing::RegistrationConsentRequirement.create!(
          registration: @registration,
          consent_document_version: version,
          required: true,
          acceptance_scope: "admission_slot",
          package_unit_number: 1,
          admission_position: 1,
          status: "pending",
          required_reason: "initial_submission",
          required_by: @manager,
          required_at: Time.current
        )
      end
    end
  end
end
