# frozen_string_literal: true

require "test_helper"

module Core
  module PhoneIdentity
    class ResolveGuestTest < ActiveSupport::TestCase
      test "creates and returns an unauthenticated shadow identity for a valid phone" do
        phone = format("+251911%06d", SecureRandom.random_number(1_000_000))
        users_before = Core::User.count

        result = ResolveGuest.call(phone:)

        assert_predicate result, :success?, result.error&.message
        assert_equal users_before + 1, Core::User.count
        assert_equal phone.delete_prefix("+"), result.value.user.phone.delete_prefix("+")
        assert_nil result.value.user.password_digest
        assert_nil result.value.user.verified_at
      end

      test "rejects a phone that already belongs to an authenticated account" do
        user = core_users(:attendee)

        result = ResolveGuest.call(phone: user.phone)

        assert_predicate result, :failure?
        assert_equal "guest_requires_authentication", result.error.code
        assert_equal :conflict, result.error.status
      end

      test "preserves invalid phone failures from the canonical resolver" do
        result = ResolveGuest.call(phone: "+251711000003")

        assert_predicate result, :failure?
        assert_equal "phone_identity_invalid", result.error.code
      end
    end
  end
end
