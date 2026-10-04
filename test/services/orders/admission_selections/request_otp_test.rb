# frozen_string_literal: true

require "test_helper"

module Orders
  module AdmissionSelections
    class RequestOtpTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @event.update!(status: "published")
        @actor = core_users(:super_admin)
        @quoted_at = Time.current.change(usec: 0)
        create_messaging_policy
        create_checkout_terms
        @delivered_codes = []
        @previous_sender = Rails.application.config.x.phone_verification_sender
        Rails.application.config.x.phone_verification_sender = lambda do |phone:, code:, challenge:|
          @delivered_codes << { phone:, code:, challenge_id: challenge.id }
        end
      end

      teardown do
        Rails.application.config.x.phone_verification_sender = @previous_sender
      end

      test "creates a purpose-bound OTP for an eligible zero-price admission selection" do
        product = create_ticket_product(name: "Free admission", amount_minor: 0)

        result = RequestOtp.call(
          event: @event,
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          charge_currency: "ETB",
          phone: "+251911000081",
          idempotency_key: "admission-otp-free-1"
        )

        assert_predicate result, :success?, result.error&.message
        challenge = result.value.challenge
        assert_equal "guest_admission", challenge.purpose
        assert_equal "pending", challenge.status
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_equal 1, @delivered_codes.length
      end

      test "allows an optional phone OTP for paid admission without checkout side effects" do
        product = create_ticket_product(name: "Paid admission", amount_minor: 1_500)

        result = RequestOtp.call(
          event: @event,
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          charge_currency: "ETB",
          phone: "+251911000082",
          idempotency_key: "admission-otp-paid"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "guest_admission", result.value.challenge.purpose
        assert_equal "pending", result.value.challenge.status
        assert_equal 1, @delivered_codes.length
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
        assert_empty Orders::Order.where(event: @event)
        assert_equal 0, product.inventories.sum(:held_count)
      end

      test "rejects an existing account before requesting a guest OTP" do
        product = create_ticket_product(name: "Existing account free offer", amount_minor: 0)

        result = RequestOtp.call(
          event: @event,
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          charge_currency: "ETB",
          phone: core_users(:attendee).phone,
          idempotency_key: "admission-otp-existing-account"
        )

        assert_predicate result, :failure?
        assert_equal "guest_requires_authentication", result.error.code
        assert_empty @delivered_codes
        assert_empty Core::PhoneVerificationChallenge.where(purpose: "guest_admission")
      end

      test "checks audience proof without consuming it before OTP delivery" do
        product = create_ticket_product(name: "Gated free admission", amount_minor: 0, audience: "access_code")
        raw_code = "ADMISSION-OTP-#{SecureRandom.hex(4)}"
        code = create_access_code(product.ticket_type, raw_code)

        result = RequestOtp.call(
          event: @event,
          items: [ {
            event_product_id: product.id,
            quantity: 1,
            answers: [],
            consents: [],
            audience_proof: { access_code: raw_code }
          } ],
          charge_currency: "ETB",
          phone: "+251911000083",
          idempotency_key: "admission-otp-gated"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal 0, code.reload.used_count
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      end

      test "allows optional OTP for a mixed free and paid selection without checkout side effects" do
        free_product = create_ticket_product(name: "Free selection line", amount_minor: 0)
        paid_product = create_ticket_product(name: "Paid selection line", amount_minor: 100)

        operation = lambda do
          RequestOtp.call(
            event: @event,
            items: [
              { event_product_id: free_product.id, quantity: 1, answers: [], consents: [] },
              { event_product_id: paid_product.id, quantity: 1, answers: [], consents: [] }
            ],
            charge_currency: "ETB",
            phone: "+251911000084",
            idempotency_key: "admission-otp-mixed"
          )
        end
        # Quote/form preflight intentionally validates every distinct offer;
        # Prosopite's read-path checks remain active in the controller suites.
        result = ENV["N_PLUS_ONE"] == "1" ? Prosopite.pause(&operation) : operation.call

        assert_predicate result, :success?, result.error&.message
        assert_equal "pending", result.value.challenge.status
        assert_equal 1, @delivered_codes.length
        assert_empty Ticketing::Registration.where(
          ticket_type_id: [ free_product.ticket_type.id, paid_product.ticket_type.id ]
        )
        assert_empty Orders::Order.where(event: @event)
        assert_equal 0, Catalog::ProductInventory.where(event_product_id: [ free_product.id, paid_product.id ]).sum(:held_count)
      end

      test "prices a guest ticket-and-add-on OTP selection without checkout side effects" do
        ticket = create_ticket_product(name: "Guest bundle ticket", amount_minor: 1_000)
        merchandise = create_add_on_product(name: "Guest bundle shirt", amount_minor: 250)

        result = RequestOtp.call(
          event: @event,
          items: [
            { event_product_id: ticket.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: merchandise.id, quantity: 2 }
          ],
          charge_currency: "ETB",
          phone: "+251911000087",
          idempotency_key: "admission-otp-ticket-addon"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "guest_admission", result.value.challenge.purpose
        assert_equal 1, @delivered_codes.length
        assert_empty Ticketing::Registration.where(ticket_type: ticket.ticket_type)
        assert_empty Orders::Order.where(event: @event)
        assert_equal 0, merchandise.inventories.sole.held_count
      end

      test "rejects an invalid ticket access code in a mixed OTP selection before delivery" do
        ticket = create_ticket_product(name: "Gated mixed ticket", amount_minor: 1_000, audience: "access_code")
        raw_code = "MIXED-OTP-#{SecureRandom.hex(4)}"
        code = create_access_code(ticket.ticket_type, raw_code)
        merchandise = create_add_on_product(name: "Gated basket shirt", amount_minor: 250)
        users_before = Core::User.count

        result = RequestOtp.call(
          event: @event,
          items: [
            {
              event_product_id: ticket.id,
              quantity: 1,
              answers: [],
              consents: [],
              audience_proof: { access_code: "wrong-code" }
            },
            { event_product_id: merchandise.id, quantity: 1 }
          ],
          charge_currency: "ETB",
          phone: "+251911000088",
          idempotency_key: "admission-otp-mixed-invalid-ticket-proof"
        )

        assert_predicate result, :failure?
        assert_empty @delivered_codes
        assert_equal users_before, Core::User.count
        assert_equal 0, code.reload.used_count
        assert_empty Ticketing::Registration.where(ticket_type: ticket.ticket_type)
        assert_empty Orders::Order.where(event: @event)
        assert_equal 0, merchandise.inventories.sole.held_count
      end

      test "rejects ticket-only proof on an add-on before guest OTP delivery" do
        ticket = create_ticket_product(name: "Public mixed OTP ticket", amount_minor: 1_000)
        merchandise = create_add_on_product(name: "Invalid OTP proof shirt", amount_minor: 250)
        users_before = Core::User.count
        challenges_before = Core::PhoneVerificationChallenge.count

        result = RequestOtp.call(
          event: @event,
          items: [
            { event_product_id: ticket.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: merchandise.id, quantity: 1, audience_proof: { access_code: "not-applicable" } }
          ],
          charge_currency: "ETB",
          phone: "+251911000089",
          idempotency_key: "admission-otp-addon-proof"
        )

        assert_predicate result, :failure?
        assert_equal "admission_selection_invalid", result.error.code
        assert_empty @delivered_codes
        assert_equal users_before, Core::User.count
        assert_equal challenges_before, Core::PhoneVerificationChallenge.count
        assert_equal 0, merchandise.inventories.sole.held_count
      end

      test "rejects OTP when a date-bound add-on has no per-date inventory" do
        ticket = create_ticket_product(name: "Configured OTP ticket", amount_minor: 1_000)
        event_date = ticket.product_accesses.sole.event_date
        parking = create_add_on_product(
          name: "Unconfigured OTP parking", amount_minor: 250, type: "parking",
          inventory_mode: "per_date", access_dates: [ event_date ], access_type: "parking"
        )
        users_before = Core::User.count
        challenges_before = Core::PhoneVerificationChallenge.count

        result = RequestOtp.call(
          event: @event,
          items: [
            { event_product_id: ticket.id, quantity: 1, answers: [], consents: [] },
            { event_product_id: parking.id, quantity: 1, event_date_ids: [ event_date.id ] }
          ],
          charge_currency: "ETB",
          phone: "+251911000090",
          idempotency_key: "admission-otp-unconfigured-parking"
        )

        assert_predicate result, :failure?
        assert_equal "inventory_not_configured", result.error.code
        assert_empty @delivered_codes
        assert_equal users_before, Core::User.count
        assert_equal challenges_before, Core::PhoneVerificationChallenge.count
        assert_empty Ticketing::Registration.where(ticket_type: ticket.ticket_type)
        assert_empty Orders::Order.where(event: @event)
      end

      test "requests OTP when a valid promotion makes the final quote zero" do
        product = create_ticket_product(name: "Discounted admission", amount_minor: 1_500)
        promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Full admission discount",
          type: "percentage",
          percentage_basis_points: 10_000,
          currency: "ETB",
          status: "active"
        )
        code = "FREEADMISSION"
        Catalog::PromotionCode.create!(
          promotion:,
          code:,
          code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code:)
        )

        result = RequestOtp.call(
          event: @event,
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          charge_currency: "ETB",
          promotion_code: code,
          phone: "+251911000085",
          idempotency_key: "admission-otp-promotion-zero"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "guest_admission", result.value.challenge.purpose
        assert_equal 1, @delivered_codes.length
        assert_empty Ticketing::Registration.where(ticket_type: product.ticket_type)
      end

      test "rejects an invalid promotion before creating an OTP identity" do
        product = create_ticket_product(name: "Admission with bad code", amount_minor: 0)
        users_before = Core::User.count

        result = RequestOtp.call(
          event: @event,
          items: [ { event_product_id: product.id, quantity: 1, answers: [], consents: [] } ],
          charge_currency: "ETB",
          promotion_code: "NOT-A-REAL-CODE",
          phone: "+251911000086",
          idempotency_key: "admission-otp-invalid-promotion"
        )

        assert_predicate result, :failure?
        assert_equal "invalid_promotion_code", result.error.code
        assert_equal users_before, Core::User.count
        assert_empty @delivered_codes
      end

      private

      def create_ticket_product(name:, amount_minor:, audience: "public")
        result = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name:, type: "ticket" },
          ticket_type_attributes: {
            audience:, approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { type: "base", currency: "ETB", amount_minor:, active_from: 1.minute.ago },
          inventory_configuration: { mode: "unlimited" }
        )
        assert_predicate result, :success?, result.error&.message
        date = @event.event_dates.create!(
          name: "Admission OTP date #{SecureRandom.hex(3)}",
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 2.hours,
          status: "scheduled"
        )
        result.value.product_accesses.create!(event_date: date, type: "venue")
        activated = Catalog::Products::Activate.call(product: result.value, actor: @actor)
        assert_predicate activated, :success?, activated.error&.message
        activated.value
      end

      def create_add_on_product(
        name:, amount_minor:, type: "merchandise", inventory_mode: "event_wide", capacity: 10,
        inventory_dates: [], access_dates: [], access_type: nil
      )
        product = Catalog::EventProduct.create!(
          event: @event,
          name:,
          type:,
          status: "active",
          inventory_mode:,
          schedule_change_refund_policy: "full_or_partial",
          min_per_order: 1
        )
        Catalog::ProductPrice.create!(
          event_product: product,
          type: "base",
          currency: "ETB",
          amount_minor:,
          active_from: @quoted_at - 1.minute
        )
        if inventory_mode.in?(%w[event_wide event_wide_and_per_date])
          Catalog::ProductInventory.create!(event_product: product, capacity:)
        end
        if inventory_mode.in?(%w[per_date event_wide_and_per_date])
          inventory_dates.each do |event_date|
            Catalog::ProductInventory.create!(event_product: product, event_date:, capacity:)
          end
        end
        access_dates.each do |event_date|
          product.product_accesses.create!(event_date:, type: access_type)
        end
        product
      end

      def create_access_code(ticket_type, raw_code)
        Ticketing::AccessCode.create!(
          ticket_type:,
          code_digest: Ticketing::AccessCode.code_digest_for(
            event_id: ticket_type.event_product.event_id, code: raw_code
          ),
          max_uses: 5,
          max_quantity_per_use: 1,
          active: true
        )
      end

      def create_checkout_terms
        schedule = create_schedule(
          code: "admission_otp_#{SecureRandom.hex(5)}",
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
  end
end
