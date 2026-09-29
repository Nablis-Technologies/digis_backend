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

    test "retains internal invitation alias only for non-public command input" do
      raw_item = {
        event_product_id: "product-1",
        quantity: 1,
        audience_proof: { invitation: "internal-invitation" }
      }

      item = Orders::AdmissionSelectionEnvelope.new(items: [ raw_item ]).items.sole

      assert_equal "internal-invitation", item.audience_proof.fetch(:invitation)
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
