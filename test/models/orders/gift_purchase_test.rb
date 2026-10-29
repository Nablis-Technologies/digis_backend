# frozen_string_literal: true

require "test_helper"

module Orders
  class GiftPurchaseTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 2)
      @order_item = @ticket.order_item
    end

    test "encrypts recipient phone, email, note, and delivery token at rest" do
      gift = build_gift
      gift.save!

      raw = Orders::GiftPurchase.connection.select_one(
        Orders::GiftPurchase.sanitize_sql_array(
          [ "SELECT recipient_phone_ciphertext, recipient_email_ciphertext, note_ciphertext, token_ciphertext " \
            "FROM orders_gift_purchases WHERE id = ?", gift.id ]
        )
      )

      assert_not_equal @owner.phone, raw.fetch("recipient_phone_ciphertext")
      assert_not_equal "gift@example.com", raw.fetch("recipient_email_ciphertext")
      assert_not_equal "A note for the recipient", raw.fetch("note_ciphertext")
      assert_not_equal "opaque-gift-capability", raw.fetch("token_ciphertext")
      assert_equal @owner.phone, gift.reload.recipient_phone
      assert_equal "gift@example.com", gift.recipient_email
      assert_equal "A note for the recipient", gift.note
      assert_equal "opaque-gift-capability", gift.token
    end

    test "rejects a note above the product limit" do
      gift = build_gift(note: "n" * 501)

      assert_not gift.valid?
      assert_includes gift.errors.attribute_names, :note
    end

    test "keeps gift expiry immutable after creation" do
      gift = build_gift
      gift.save!
      gift.expires_at += 1.second

      assert_not gift.valid?
      assert_includes gift.errors.attribute_names, :expires_at
    end

    test "persists line identity and prevents changing it after creation" do
      line_id = "c865cacc-b477-4f4b-851c-c1e64716a740"
      gift = build_gift(client_line_id: line_id)
      gift.save!

      assert_equal line_id, gift.reload.client_line_id
      assert_equal line_id, gift.payer_status_payload.fetch(:line_id)

      gift.client_line_id = "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8"
      assert_not gift.valid?
      assert_includes gift.errors.attribute_names, :client_line_id
    end

    test "allows one gift intent per order item and rejects a duplicate" do
      build_gift.save!
      duplicate = build_gift(token: "another-gift-capability")

      assert_not duplicate.valid?
      assert_includes duplicate.errors.attribute_names, :order_item_id
    end

    test "does not make encrypted details searchable through Ransack" do
      allowed = GiftPurchase.ransackable_attributes

      %w[recipient_phone_ciphertext recipient_email_ciphertext note_ciphertext token_ciphertext
         token_digest recipient_phone_digest recipient_email_digest].each do |field|
        assert_not_includes allowed, field
      end
    end

    private

    def build_gift(note: "A note for the recipient", token: "opaque-gift-capability", client_line_id: nil)
      GiftPurchase.new(
        order_item: @order_item,
        client_line_id:,
        recipient_user: @owner,
        recipient_phone: @owner.phone,
        recipient_phone_digest: GiftPurchase.recipient_phone_digest_for(phone: @owner.phone),
        recipient_email: "gift@example.com",
        recipient_email_digest: GiftPurchase.recipient_email_digest_for(email: "gift@example.com"),
        note:,
        token:,
        token_digest: GiftPurchase.token_digest_for(token:),
        status: "ready",
        ready_at: Time.current,
        delivery_status: "pending",
        expires_at: 2.days.from_now
      )
    end
  end
end
