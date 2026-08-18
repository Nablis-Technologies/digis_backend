# frozen_string_literal: true

require "test_helper"

module Ticketing
  class CredentialGenerationConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @manager = core_users(:super_admin)
      @product = create_ticket_product
      @registration = create_registration
      @ticket = create_ticket
    end

    teardown do
      Ticketing::ApplicationRecord.transaction do
        credential_ids = Ticketing::Credential.where(ticket_id: @ticket.id).pluck(:id)
        Ticketing::CredentialRevocation.where(credential_id: credential_ids).delete_all
        Ticketing::AttendeeIndexEntry.where(ticket_id: @ticket.id).delete_all
        Ticketing::Credential.where(id: credential_ids).delete_all
        Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).delete_all
        Ticketing::AdmissionSlot.where(ticket_id: @ticket.id).delete_all
        Ticketing::Revocation.where(ticket_id: @ticket.id).delete_all
        Core::OutboxEvent.where(aggregate_id: @ticket.id).delete_all
        Ticketing::Ticket.where(id: @ticket.id).delete_all
      end
      @order.update_columns(status: "draft", paid_at: nil)
      Orders::OrderItem.where(id: @order_item.id).delete_all
      Orders::Order.where(id: @order.id).delete_all
      Ticketing::Registration.where(id: @registration.id).delete_all
      Catalog::ProductAccess.where(event_product_id: @product.id).delete_all
      Ticketing::TicketType.where(event_product_id: @product.id).delete_all
      Catalog::EventProduct.where(id: @product.id).delete_all
      Events::EventDate.where(id: @event_date.id).delete_all
    end

    test "serializes concurrent replacements into one active complete generation" do
      ready = Queue.new
      start = Queue.new
      key = "delegate:#{@ticket.id}:concurrent"
      threads = 2.times.map do
        Thread.new do
          ready << true
          start.pop
          Ticketing::ApplicationRecord.connection_pool.with_connection do
            Ticketing::CredentialGenerations::Replace.call(
              ticket: Ticketing::Ticket.find(@ticket.id),
              target_mode: "delegated",
              reason: "owner_delegated",
              assignments: { 1 => Core::User.find(@buyer.id), 2 => nil, 3 => nil },
              idempotency_key: key
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = threads.map(&:value)

      assert results.all?(&:success?), results.map { |result| result.error&.code }.inspect
      assert_equal 2, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count
      assert_equal 1, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id, status: "active").count
      assert_equal 1, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id, version: 2).count
      assert_equal 3, Ticketing::Credential.where(
        ticket_id: @ticket.id, credential_generation_id: @ticket.reload.current_credential_generation_id
      ).count
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_id: @ticket.id, event_type: "ticketing.credential_generation_replaced"
      ).count
    ensure
      threads&.each(&:join)
    end

    private

    def create_ticket_product
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @manager,
        product_attributes: { name: "Concurrency ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public",
          approval_mode: "automatic",
          date_selection: "fixed",
          admissions_per_unit: 3,
          delegation_enabled: true
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      @event_date = @event.event_dates.create!(
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 4.hours,
        status: "scheduled"
      )
      product.product_accesses.create!(event_date: @event_date, type: "venue", usage_limit: 1)
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

    def create_ticket
      @order = Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
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
        creation_request_digest: SecureRandom.hex(32)
      )
      @order_item = Orders::OrderItem.create!(
        order: @order,
        event_product: @product,
        registration: @registration,
        name_snapshot: @product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: 3,
        base_currency: "ETB",
        base_unit_amount_minor: 3_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 3_000,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 3_000,
        fulfillment_status: "fulfilled"
      )
      @order.update_columns(status: "fulfilled", paid_at: Time.current)

      Ticketing::Packages::Issue.call(order_item: @order_item, unit_number: 1).value
    end
  end
end
