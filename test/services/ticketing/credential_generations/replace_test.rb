# frozen_string_literal: true

require "test_helper"

module Ticketing
  module CredentialGenerations
    class ReplaceTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @buyer = core_users(:attendee)
        @manager = core_users(:super_admin)
        @product = create_ticket_product
        @registration = create_registration
        @ticket = create_ticket
      end

      test "replaces group with one individual credential per slot" do
        prior_generation = @ticket.current_credential_generation
        prior_credential = prior_generation.credentials.sole

        result = Ticketing::CredentialGenerations::Replace.call(
          ticket: @ticket,
          target_mode: "delegated",
          reason: "owner_delegated",
          assignments: { 1 => @buyer, 2 => nil, 3 => nil },
          idempotency_key: "delegate:#{@ticket.id}:v2"
        )

        assert_predicate result, :success?, result.error&.message
        generation = result.value

        assert_equal 2, generation.version
        assert_equal "delegated", generation.mode
        assert_equal 3, generation.credentials.count
        assert generation.credentials.all? { |credential| credential.type == "individual" }
        assert_equal [ 1, 2, 3 ], generation.credentials.map { |credential| credential.admission_slot.position }.sort
        assert_equal "revoked", prior_generation.reload.status
        assert_equal "revoked", prior_credential.reload.status
        assert_predicate prior_credential.attendee_index_entry.reload, :removed
        assert_equal [ "claimed", "pending_claim", "pending_claim" ],
          @ticket.admission_slots.order(:position).pluck(:assignment_status)
        assert_equal 1, Ticketing::Credential.where(credential_generation_id: generation.id, status: "active").count
        assert_equal 2, Ticketing::Credential.where(credential_generation_id: generation.id, status: "pending_claim").count
        event = Core::OutboxEvent.find_by!(aggregate_id: @ticket.id,
          event_type: "ticketing.credential_generation_replaced")
        assert_equal({ "ticket_id" => @ticket.id, "version" => 2 }, event.payload)
      end

      test "replays the same replacement without creating another generation" do
        subject = lambda do
          Ticketing::CredentialGenerations::Replace.call(
            ticket: @ticket,
            target_mode: "delegated",
            reason: "owner_delegated",
            assignments: { 1 => @buyer, 2 => nil, 3 => nil },
            idempotency_key: "delegate:#{@ticket.id}:replay"
          )
        end

        assert_idempotent(subject, counter: -> { Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count })
      end

      test "activates delegated credentials independently of a pending personal requirement" do
        create_pending_personal_requirement(position: 1)

        result = Ticketing::CredentialGenerations::Replace.call(
          ticket: @ticket,
          target_mode: "delegated",
          reason: "owner_delegated",
          assignments: { 1 => @buyer, 2 => nil, 3 => @buyer },
          idempotency_key: "delegate:#{@ticket.id}:requirements"
        )

        assert_predicate result, :success?, result.error&.message
        credentials = result.value.credentials.index_by { |credential| credential.admission_slot.position }
        assert_equal "pending_requirements", credentials.fetch(1).status
        assert_equal "active", credentials.fetch(3).status
        assert_empty Ticketing::AttendeeIndexEntry.where(credential_id: credentials.fetch(1).id)
        assert_predicate credentials.fetch(3).attendee_index_entry, :present?
      end

      test "replaces delegated credentials with one new group credential" do
        delegated = Ticketing::CredentialGenerations::Replace.call(
          ticket: @ticket,
          target_mode: "delegated",
          reason: "owner_delegated",
          assignments: { 1 => @buyer, 2 => nil, 3 => nil },
          idempotency_key: "delegate:#{@ticket.id}:forward"
        ).value

        result = Ticketing::CredentialGenerations::Replace.call(
          ticket: @ticket,
          target_mode: "group",
          reason: "delegation_cancelled",
          assignments: {},
          idempotency_key: "delegate:#{@ticket.id}:cancel"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal 3, result.value.version
        assert_equal "group", result.value.mode
        assert_equal "package", result.value.credentials.sole.type
        assert_equal "revoked", delegated.reload.status
        assert_equal 3, Ticketing::CredentialRevocation.where(
          credential_id: delegated.credentials.select(:id)
        ).count
      end

      test "rejects an incomplete assignment without changing the active generation" do
        result = Ticketing::CredentialGenerations::Replace.call(
          ticket: @ticket,
          target_mode: "delegated",
          reason: "owner_delegated",
          assignments: { 1 => @buyer },
          idempotency_key: "delegate:#{@ticket.id}:invalid"
        )

        assert_predicate result, :failure?
        assert_equal "invalid_generation_assignments", result.error.code
        assert_equal 1, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count
        assert_equal "active", @ticket.current_credential_generation.reload.status
        assert_empty Core::OutboxEvent.where(
          aggregate_id: @ticket.id, event_type: "ticketing.credential_generation_replaced"
        )
      end

      test "dispatches replacement delivery through the registered outbox handler" do
        result = Ticketing::CredentialGenerations::Replace.call(
          ticket: @ticket,
          target_mode: "delegated",
          reason: "owner_delegated",
          assignments: { 1 => @buyer, 2 => nil, 3 => nil },
          idempotency_key: "delegate:#{@ticket.id}:delivery"
        )
        assert_predicate result, :success?, result.error&.message
        event = Core::OutboxEvent.find_by!(aggregate_id: @ticket.id,
          event_type: "ticketing.credential_generation_replaced")
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
        assert_equal(
          { ticket_id: @ticket.id, version: 2, idempotency_key: event.idempotency_key },
          delivered
        )
      end

      private

      def create_ticket_product
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "Replace ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public",
            approval_mode: "automatic",
            date_selection: "fixed",
            admissions_per_unit: 3,
            delegation_enabled: true
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

      def create_ticket
        order = Orders::Order.create!(
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
        item = Orders::OrderItem.create!(
          order:,
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
        order.update_columns(status: "fulfilled", paid_at: Time.current)

        Ticketing::Packages::Issue.call(order_item: item, unit_number: 1).value
      end

      def create_pending_personal_requirement(position:)
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
          admission_position: position,
          status: "pending",
          required_reason: "initial_submission",
          required_by: @manager,
          required_at: Time.current
        )
      end
    end
  end
end
