# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Qr
    class SignerTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @buyer = core_users(:attendee)
        @manager = core_users(:super_admin)
        @product = create_ticket_product
        @registration = create_registration
        @credential = create_active_credential
      end

      test "signs the exact credential claims and verifier round trips them" do
        result = Ticketing::Qr::Verifier.call(token: @credential.qr_token)

        assert_predicate result, :success?, result.error&.message
        assert_equal(
          %i[kid cid tid eid mode slots entry_limit v accesses exp],
          result.value.to_h.keys
        )
        assert_equal @credential.id, result.value.cid
        assert_equal @credential.ticket_id, result.value.tid
        assert_equal @credential.event_id, result.value.eid
        assert_equal [ 1, 2, 3 ], result.value.slots
        assert_equal "group", result.value.mode
      end

      test "rejects a tampered signed payload" do
        envelope = JSON.parse(Base64.urlsafe_decode64(@credential.qr_token))
        envelope["entry_limit"] = 99
        tampered = Base64.urlsafe_encode64(JSON.generate(envelope), padding: false)

        result = Ticketing::Qr::Verifier.call(token: tampered)

        assert_predicate result, :failure?
        assert_equal "invalid_qr_signature", result.error.code
      end

      test "rejects a signed payload with an unexpected claim" do
        payload = Ticketing::Qr::Verifier.call(token: @credential.qr_token).value.to_h.stringify_keys
        payload["unexpected"] = "private-data"
        token = signed_token(payload)

        result = Ticketing::Qr::Verifier.call(token: token)

        assert_predicate result, :failure?
        assert_equal "invalid_credential_claims", result.error.code
      end

      test "rejects malformed, unknown-key, and expired tokens" do
        malformed = Ticketing::Qr::Verifier.call(token: "not-a-token")
        assert_predicate malformed, :failure?
        assert_equal "invalid_qr_token", malformed.error.code

        unknown_key_payload = Ticketing::Qr::Verifier.call(token: @credential.qr_token).value.to_h.stringify_keys
        unknown_key_payload["kid"] = "retired"
        unknown_key = Ticketing::Qr::Verifier.call(token: signed_token(unknown_key_payload))
        assert_predicate unknown_key, :failure?
        assert_equal "unknown_qr_key", unknown_key.error.code

        expired_payload = Ticketing::Qr::Verifier.call(token: @credential.qr_token).value.to_h.stringify_keys
        expired_payload["exp"] = 1
        expired = Ticketing::Qr::Verifier.call(token: signed_token(expired_payload))
        assert_predicate expired, :failure?
        assert_equal "expired_qr_token", expired.error.code
      end

      private

      def signed_token(payload)
        signing_key = Rails.application.config.x.ticketing_qr_signing_keys.fetch("v1")
        signature = signing_key.sign(Ticketing::Qr::Signer.canonical_json(payload.except("sig")))
        envelope = payload.merge("sig" => Base64.strict_encode64(signature))
        Base64.urlsafe_encode64(JSON.generate(envelope), padding: false)
      end

      def create_ticket_product
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @manager,
          product_attributes: { name: "QR ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public",
            approval_mode: "automatic",
            date_selection: "fixed",
            admissions_per_unit: 3
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

      def create_active_credential
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

        Ticketing::Packages::Issue.call(order_item: item, unit_number: 1).value.credentials.sole
      end
    end
  end
end
