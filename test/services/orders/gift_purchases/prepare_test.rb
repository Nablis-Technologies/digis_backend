# frozen_string_literal: true

require "test_helper"

module Orders
  module GiftPurchases
    class PrepareTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @purchaser = core_users(:attendee)
        @ticket_type = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Prepared gift #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, waitlist_enabled: false
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
        @event_date = @event.event_dates.create!(
          starts_at: 2.days.from_now,
          ends_at: 2.days.from_now + 2.hours,
          status: "scheduled"
        )
        @ticket_type.event_product.product_accesses.create!(event_date: @event_date, type: "venue")
      end

      test "prepares a normalized recipient intent without persisting a gift before checkout" do
        assert_no_difference -> { Orders::GiftPurchase.count } do
          result = Prepare.call(
            ticket_type: @ticket_type,
            purchaser: @purchaser,
            recipient_phone: "0911000101",
            recipient_email: "  GIFT@EXAMPLE.COM ",
            note: "  Happy birthday!  ",
            package_quantity: 1,
            selected_event_date_id: nil,
            idempotency_key: "prepared-gift-intent"
          )

          assert_predicate result, :success?, result.error&.message
          assert_equal "+251911000101", result.value.recipient_phone
          assert_equal "gift@example.com", result.value.recipient_email
          assert_equal "Happy birthday!", result.value.note
          assert_equal "gift_pending_claim", result.value.registration.status
          assert_equal Core::User.find_by!(phone: "+251911000101"), result.value.recipient
          assert_equal @event_date.ends_at, result.value.expires_at
        end
      end

      test "rejects gift notes over the bounded plaintext limit without writing a registration" do
        result = Prepare.call(
          ticket_type: @ticket_type,
          purchaser: @purchaser,
          recipient_phone: "0911000102",
          note: "n" * 501,
          package_quantity: 1,
          idempotency_key: "oversized-gift-note"
        )

        assert_predicate result, :failure?
        assert_equal "gift_note_too_long", result.error.code
        assert_nil Core::User.find_by(phone: "+251911000102")
        assert_equal 0, Ticketing::Registration.where(ticket_type: @ticket_type).count
      end

      test "rejects the payer as recipient before creating a registration" do
        result = Prepare.call(
          ticket_type: @ticket_type,
          purchaser: @purchaser,
          recipient_phone: @purchaser.phone,
          package_quantity: 1,
          idempotency_key: "self-gift"
        )

        assert_predicate result, :failure?
        assert_equal "gift_recipient_same_as_purchaser", result.error.code
        assert_equal 0, Ticketing::Registration.where(ticket_type: @ticket_type).count
      end
    end
  end
end
