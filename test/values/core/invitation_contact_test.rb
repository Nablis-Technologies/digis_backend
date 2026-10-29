# frozen_string_literal: true

require "test_helper"

module Core
  class InvitationContactTest < ActiveSupport::TestCase
    test "normalizes Ethiopian phone input and masks it for display" do
      contact = Core::InvitationContact.parse(phone: "0911 223 344")

      assert_equal :phone, contact.type
      assert_equal "+251911223344", contact.normalized_value
      assert_equal "+2519***44", contact.masked_value
    end

    test "normalizes email casing and surrounding whitespace without verifying it" do
      contact = Core::InvitationContact.parse(email: "  Teammate@Example.COM  ")

      assert_equal :email, contact.type
      assert_equal "teammate@example.com", contact.normalized_value
      assert_equal "t***@example.com", contact.masked_value
    end

    test "scopes storage digest by domain, parent and contact type" do
      contact = Core::InvitationContact.parse(phone: "+251911223344")

      organization_digest = contact.digest_for(scope_type: "organization_membership", scope_id: "org-1")
      another_org_digest = contact.digest_for(scope_type: "organization_membership", scope_id: "org-2")
      event_digest = contact.digest_for(scope_type: "event_staff", scope_id: "event-1")

      assert_match(/\A[0-9a-f]{64}\z/, organization_digest)
      refute_equal organization_digest, another_org_digest
      refute_equal organization_digest, event_digest
      assert_match(/\A[0-9a-f]{64}\z/, contact.rate_limit_digest)
    end

    test "uses the same rate-limit digest for the same contact across scopes" do
      first = Core::InvitationContact.parse(phone: "0911223344")
      second = Core::InvitationContact.parse(phone: "+251911223344")

      assert_equal first.rate_limit_digest, second.rate_limit_digest
    end

    test "rejects missing, ambiguous and invalid contact inputs" do
      assert_raises(ArgumentError) { Core::InvitationContact.parse }
      assert_raises(ArgumentError) { Core::InvitationContact.parse(phone: "0911223344", email: "a@example.com") }
      assert_raises(ArgumentError) { Core::InvitationContact.parse(phone: "abc") }
      assert_raises(ArgumentError) { Core::InvitationContact.parse(email: "invalid-address") }
    end
  end
end
