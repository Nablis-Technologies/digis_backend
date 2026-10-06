# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationTest < ActiveSupport::TestCase
    include Ticketing::ConsentTestHelpers

    setup do
      setup_consent_context
    end

    test "gift-pending registration has a distinct recipient-claim action" do
      assert_includes Registration::STATUSES, "gift_pending_claim"
      assert_equal "gift_claim_pending", RegistrationNextAction.type_for("gift_pending_claim")
    end

    test "gift-pending registration blocks duplicate registrations" do
      @registration.update!(status: "gift_pending_claim")

      assert_includes Registration.active, @registration
      assert_includes Registration.blocking_duplicate, @registration
    end
  end
end
