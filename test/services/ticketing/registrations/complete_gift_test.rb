# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Registrations
    class CompleteGiftTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers

      setup do
        setup_gift_purchase_context
      end

      test "persists recipient answers and consents before confirming the paid registration" do
        _form, _version, question = create_required_gift_form
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1,
          selected_event_date_id: nil,
          answers: [ { question_key: question.key, value: "Gift recipient" } ],
          consents: []
        )

        result = CompleteGift.call(
          registration: @gift_registration,
          actor: @gift_purchase.recipient_user,
          submission:,
          idempotency_key: "complete-gift-registration"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "confirmed", @gift_registration.reload.status
        answer = @gift_registration.form_submissions.sole.answers.sole
        assert_equal "Gift recipient", answer.answer
      end

      test "rejects a registration that is no longer awaiting a gift claim" do
        @gift_registration.update_columns(status: "cancelled")
        submission = Ticketing::RegistrationSubmission.new(
          package_quantity: 1, selected_event_date_id: nil, answers: [], consents: []
        )

        result = CompleteGift.call(
          registration: @gift_registration,
          actor: @gift_purchase.recipient_user,
          submission:,
          idempotency_key: "complete-unpaid-gift-registration"
        )

        assert_predicate result, :failure?
        assert_equal "gift_registration_not_pending", result.error.code
        assert_equal "cancelled", @gift_registration.reload.status
        assert_empty @gift_registration.form_submissions
      end
    end
  end
end
