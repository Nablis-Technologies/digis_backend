# frozen_string_literal: true

require "test_helper"

module Core
  module PhoneIdentity
    class ResolveOrCreateTest < ActiveSupport::TestCase
      setup do
        @actor = core_users(:attendee)
      end

      test "resolves Ethiopia local trunk and E.164 mobile forms to one identity digest" do
        local = ResolveOrCreate.call(phone: "0911000003", actor: @actor)
        e164 = ResolveOrCreate.call(phone: "+251911000003", actor: @actor)

        assert_predicate local, :success?
        assert_predicate e164, :success?
        assert_equal @actor, local.value.user
        assert_equal local.value.digest, e164.value.digest
      end

      test "rejects malformed Ethiopia phone input with a typed failure" do
        result = ResolveOrCreate.call(phone: "+251711000003", actor: @actor)

        assert_predicate result, :failure?
        assert_equal "phone_identity_invalid", result.error.code
      end

      test "resolves a manager recipient against the existing canonical user" do
        users_before = Core::User.count

        result = ResolveOrCreate.call(
          phone: "251911000002",
          actor: @actor,
          allow_actor_mismatch: true
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal core_users(:core_admin).id, result.value.user.id
        assert_equal users_before, Core::User.count
      end
    end
  end
end
