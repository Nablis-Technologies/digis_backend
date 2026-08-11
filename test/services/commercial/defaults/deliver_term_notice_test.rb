# frozen_string_literal: true

require "test_helper"

module Commercial
  module Defaults
    class DeliverTermNoticeTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @organization = organizations_organizations(:one)
        @legal_version = create_published_legal_version
        @version = create_simulatable_version(
          code: "default_notice", schedule_type: "platform_default",
          effective_from: 2.days.from_now, attributes: { legal_document_version: @legal_version,
                                                          acceptance_policy: "notice_only" }
        )
        @version.update!(status: "scheduled")
      end

      test "creates one exact delivered notice and makes it visible to members" do
        result = DeliverTermNotice.call(
          organization: @organization, version: @version, actor: core_users(:super_admin),
          idempotency_key: "default-notice-1"
        )

        assert result.success?, result.error&.message
        notice = result.value
        assert_equal "delivered", notice.status
        assert_equal @version.id, notice.fee_schedule_version_id
        assert notice.visible_to?(core_users(:super_admin))
        assert_equal 1, TermNotice.count

        replay = DeliverTermNotice.call(
          organization: @organization, version: @version, actor: core_users(:super_admin),
          idempotency_key: "default-notice-1"
        )
        assert replay.success?, replay.error&.message
        assert_equal 1, TermNotice.count
        assert_equal 1, Core::AuditLog.where(action: "commercial.term_notice.delivered").count
      end
    end
  end
end
