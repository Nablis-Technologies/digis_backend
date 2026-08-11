# frozen_string_literal: true

require "test_helper"

module Commercial
  class CommercialAuthorizationTest < ActiveSupport::TestCase
    COMMERCIAL_PERMISSION_CODES = %w[
      commercial.view
      commercial.draft
      commercial.simulate
      commercial.submit
      commercial.approve
      commercial.activate
      commercial.grant
      commercial.terminate
      commercial.audit
      commercial.budget_view
      commercial.break_glass
    ].freeze

    test "dedicated commercial permission codes exist as independent records" do
      permissions = Core::Permission.where(code: COMMERCIAL_PERMISSION_CODES).index_by(&:code)

      assert_equal COMMERCIAL_PERMISSION_CODES.sort, permissions.keys.sort
      permissions.each_value do |permission|
        assert_equal "commercial", permission.resource
        assert_equal "commercial", permission.namespace
        assert COMMERCIAL_PERMISSION_CODES.include?(permission.code)
      end
    end

    test "non-super-admin commercial access is granted by an exact permission" do
      actor = core_users(:core_admin)

      assert actor.has_role?("CORE_ADMIN")
      assert_not actor.super_admin?
      assert actor.has_permission?("commercial.view")
      assert_not actor.has_permission?("commercial.approve")
      assert_not actor.has_permission?("commercial.break_glass")
      assert_not actor.has_permission?("commercial.all")
    end

    test "super-admin remains the explicit override" do
      actor = core_users(:super_admin)

      assert actor.super_admin?
      COMMERCIAL_PERMISSION_CODES.each do |code|
        assert actor.has_permission?(code)
      end
    end
  end
end
