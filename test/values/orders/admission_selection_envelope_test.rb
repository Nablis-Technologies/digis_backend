# frozen_string_literal: true

require "test_helper"

module Orders
  class AdmissionSelectionEnvelopeTest < ActiveSupport::TestCase
    test "normalizes nested public params through immutable allowlisted item data" do
      raw_items = ActionController::Parameters.new(
        items: [ {
          event_product_id: "product-1",
          registration_id: "",
          quantity: 2,
          selected_event_date_id: "date-1",
          amount_minor: 99_999,
          answers: [ { form_version_id: "form-1", question_key: "name", value: "Ada", secret: "no" } ],
          consents: [ { request_uuid: "request-1", consent_document_version_id: "version-1", raw: "no" } ],
          audience_proof: { access_code: "CODE", invitation_token: "invite-1", invitation: "legacy" }
        } ]
      )[:items]

      item = Orders::AdmissionSelectionEnvelope.new(items: raw_items, public_payload: true).items.sole

      assert_equal "product-1", item.fetch(:event_product_id)
      assert_nil item.fetch(:registration_id)
      assert_equal 2, item.fetch(:quantity)
      assert_equal [ { form_version_id: "form-1", question_key: "name", value: "Ada" } ], item[:answers]
      assert_equal [ { request_uuid: "request-1", consent_document_version_id: "version-1" } ], item[:consents]
      assert_equal({ access_code: "CODE", invitation_token: "invite-1" }, item[:audience_proof])
      assert_raises(FrozenError) { item.answers.first[:value] = "changed" }
    end

    test "normalizes add-on event date ids and does not accept client venue date demand" do
      raw_items = ActionController::Parameters.new(
        items: [ {
          event_product_id: "parking-product",
          quantity: 1,
          event_date_ids: [ "date-2", "date-1", "date-2" ],
          venue_event_date_ids: [ "forged-date" ]
        } ]
      )[:items]

      item = Orders::AdmissionSelectionEnvelope.new(items: raw_items, public_payload: true).items.sole

      assert_equal [ "date-1", "date-2" ], item.to_h[:event_date_ids]
      assert_not_includes item.to_h.keys, :venue_event_date_ids
      assert_raises(FrozenError) { item.event_date_ids << "changed" }
    end

    test "retains internal invitation alias only for non-public command input" do
      raw_item = {
        event_product_id: "product-1",
        quantity: 1,
        audience_proof: { invitation: "internal-invitation" }
      }

      item = Orders::AdmissionSelectionEnvelope.new(items: [ raw_item ]).items.sole

      assert_equal "internal-invitation", item.audience_proof.fetch(:invitation)
    end

    test "normalizes and allowlists the gift recipient and note" do
      item = Orders::AdmissionSelectionEnvelope.new(
        items: [ {
          event_product_id: "gift-ticket",
          quantity: 1,
          answers: [],
          consents: [],
          gift: {
            recipient_phone: " 0911000101 ",
            recipient_email: " Gift@Example.com ",
            note: "  Happy birthday!  ",
            recipient_user_id: "forged-user",
            token: "forged-token"
          }
        } ],
        public_payload: true
      ).items.sole

      assert_equal(
        { recipient_phone: "0911000101", recipient_email: "gift@example.com", note: "Happy birthday!" },
        item.to_h[:gift]
      )
      assert_raises(FrozenError) { item.to_h[:gift][:recipient_phone] = "changed" }
    end

    test "preserves a validated client line ID for replay-safe gift mapping" do
      line_id = "c865cacc-b477-4f4b-851c-c1e64716a740"
      envelope = Orders::AdmissionSelectionEnvelope.new(
        items: [ {
          event_product_id: "gift-ticket",
          line_id:,
          quantity: 1,
          answers: [],
          consents: [],
          gift: { recipient_phone: "0911000101" }
        } ],
        public_payload: true
      )
      item = envelope.items.sole

      assert_respond_to item, :line_id
      assert_equal line_id, item.line_id
      assert_equal "client:#{line_id}", item.line_key
      assert_respond_to envelope, :valid_repeated_gift_lines?
      assert_predicate envelope, :valid_repeated_gift_lines?
    end

    test "supports repeated product IDs only for distinct quantity-one gift lines" do
      envelope = Orders::AdmissionSelectionEnvelope.new(items: [
        {
          event_product_id: "gift-ticket", line_id: "c865cacc-b477-4f4b-851c-c1e64716a740",
          quantity: 1, gift: { recipient_phone: "0911000101" }
        },
        {
          event_product_id: "gift-ticket", line_id: "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8",
          quantity: 1, gift: { recipient_phone: "0911000102" }
        }
      ])

      assert_predicate envelope, :valid_repeated_gift_lines?
      assert_equal 2, envelope.items.map(&:line_key).uniq.length
    end

    test "rejects repeated non-gift or non-unit product lines" do
      line_id = "c865cacc-b477-4f4b-851c-c1e64716a740"
      invalid_groups = [
        [
          { event_product_id: "product", line_id:, quantity: 1 },
          { event_product_id: "product", line_id: "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8", quantity: 1 }
        ],
        [
          { event_product_id: "product", line_id:, quantity: 1, gift: { recipient_phone: "0911000101" } },
          { event_product_id: "product", line_id: "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8", quantity: 1 }
        ],
        [
          { event_product_id: "product", line_id:, quantity: 1, gift: { recipient_phone: "0911000101" } },
          { event_product_id: "product", line_id: "e9c02143-2de4-41b2-8f5a-c7f1eceb9df8", quantity: 2,
            gift: { recipient_phone: "0911000102" } }
        ]
      ]

      assert_respond_to Orders::AdmissionSelectionEnvelope.new(items: []), :valid_repeated_gift_lines?
      invalid_groups.each do |items|
        envelope = Orders::AdmissionSelectionEnvelope.new(items:)
        assert_not envelope.valid_repeated_gift_lines?, items.inspect
      end
    end

    test "rejects repeated gift product lines with a missing or reused line ID" do
      first_line_id = "c865cacc-b477-4f4b-851c-c1e64716a740"
      repeated_lines = [
        [
          { event_product_id: "product", line_id: first_line_id, quantity: 1,
            gift: { recipient_phone: "0911000101" } },
          { event_product_id: "product", quantity: 1, gift: { recipient_phone: "0911000102" } }
        ],
        [
          { event_product_id: "product", line_id: first_line_id, quantity: 1,
            gift: { recipient_phone: "0911000101" } },
          { event_product_id: "product", line_id: first_line_id, quantity: 1,
            gift: { recipient_phone: "0911000102" } }
        ]
      ]

      envelope = Orders::AdmissionSelectionEnvelope.new(items: repeated_lines.first)
      assert_not envelope.valid_repeated_gift_lines?
      assert_raises(Orders::AdmissionSelectionEnvelope::InvalidInput) do
        Orders::AdmissionSelectionEnvelope.new(items: repeated_lines.second)
      end
    end

    test "rejects a line ID reused across items" do
      line_id = "c865cacc-b477-4f4b-851c-c1e64716a740"

      assert_raises(Orders::AdmissionSelectionEnvelope::InvalidInput) do
        Orders::AdmissionSelectionEnvelope.new(items: [
          { event_product_id: "product-one", line_id:, quantity: 1 },
          { event_product_id: "product-two", line_id:, quantity: 1 }
        ])
      end
    end

    test "rejects malformed line IDs" do
      assert_raises(Orders::AdmissionSelectionEnvelope::InvalidInput) do
        Orders::AdmissionSelectionEnvelope.new(
          items: [ { event_product_id: "gift-ticket", line_id: "not-a-uuid", quantity: 1 } ]
        )
      end
    end

    test "identifies recipient registration data separately from gift contact details" do
      forbidden_fields = [
        { registration_id: "registration-1" },
        { answers: [ { question_key: "name", value: "Ada" } ] },
        { consents: [ { consent_document_version_id: "version-1" } ] },
        { audience_proof: { access_code: "CODE" } }
      ]

      forbidden_fields.each do |fields|
        item = Orders::AdmissionSelectionEnvelope.new(
          items: [ {
            event_product_id: "gift-ticket",
            quantity: 1,
            answers: [],
            consents: [],
            gift: { recipient_phone: "0911000101" }
          }.merge(fields) ]
        ).items.sole

        assert_predicate item, :recipient_registration_data_present?
      end

      gift_only = Orders::AdmissionSelectionEnvelope.new(
        items: [ {
          event_product_id: "gift-ticket",
          quantity: 1,
          answers: [],
          consents: [],
          gift: { recipient_phone: "0911000101" }
        } ]
      ).items.sole

      assert_not_predicate gift_only, :recipient_registration_data_present?
    end

    test "rejects a non-object gift intent" do
      assert_raises(Orders::AdmissionSelectionEnvelope::InvalidInput) do
        Orders::AdmissionSelectionEnvelope.new(
          items: [ { event_product_id: "gift-ticket", quantity: 1, gift: "not-an-object" } ],
          public_payload: true
        )
      end
    end

    test "rejects a non-object admission item" do
      assert_raises(Orders::AdmissionSelectionEnvelope::InvalidInput) do
        Orders::AdmissionSelectionEnvelope.new(items: [ "not-an-item" ])
      end
    end

    test "shares form-row allowlisting with waitlist registration submissions" do
      raw_row = { question_key: "name", value: +"Ada", secret: "no" }
      rows = Ticketing::RegistrationSubmission.normalize_entries(
        [ raw_row ],
        permitted_fields: Ticketing::RegistrationSubmission::ANSWER_FIELDS
      )

      assert_equal [ { question_key: "name", value: "Ada" } ], rows
      assert_not_predicate raw_row, :frozen?
      assert_not_predicate raw_row[:value], :frozen?
    end
  end
end
