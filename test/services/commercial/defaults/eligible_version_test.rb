# frozen_string_literal: true

require "test_helper"

module Commercial
  module Defaults
    class EligibleVersionTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers

      setup do
        @organization = organizations_organizations(:one)
        @legal_version = create_published_legal_version
      end

      test "returns a none-policy active default" do
        version = create_active_default(acceptance_policy: "none")

        result = EligibleVersion.call(organization: @organization, at: Time.current)

        assert result.success?, result.error&.message
        assert_equal version.id, result.value.id
      end

      test "requires the exact delivered notice for notice_only" do
        version = create_active_default(acceptance_policy: "notice_only", effective_from: 1.hour.from_now)
        missing = EligibleVersion.call(organization: @organization, at: version.effective_from + 1.minute)
        assert missing.failure?
        assert_equal "notice_required", missing.error.code

        notice_result = DeliverTermNotice.call(
          organization: @organization, version:, actor: core_users(:super_admin),
          idempotency_key: "eligible-notice"
        )
        assert notice_result.success?, notice_result.error&.message
        eligible = EligibleVersion.call(organization: @organization, at: version.effective_from + 1.minute)
        assert eligible.success?, eligible.error&.message
        assert_equal version.id, eligible.value.id
      end

      test "fails closed for explicit terms without acceptance" do
        version = create_active_default(acceptance_policy: "explicit")
        result = EligibleVersion.call(organization: @organization, at: Time.current)

        assert result.failure?
        assert_equal "acceptance_required", result.error.code

        acceptance = Legal::RecordAcceptance.call(
          subject: @organization, legal_document_version: @legal_version,
          accepted_by: core_users(:super_admin)
        )
        assert acceptance.success?, acceptance.error&.message
        eligible = EligibleVersion.call(organization: @organization, at: Time.current)
        assert eligible.success?, eligible.error&.message
        assert_equal version.id, eligible.value.id
      end

      test "returns the accepted previous version during its explicit grandfather window" do
        previous_legal_version = create_published_legal_version
        schedule = create_schedule(
          code: "grandfathered_default_#{SecureRandom.hex(2)}", schedule_type: "platform_default"
        )
        previous = create_version(
          schedule,
          version: 1, status: "draft", effective_from: 3.days.ago,
          legal_document_version: previous_legal_version, acceptance_policy: "explicit"
        )
        populate_simulatable_version(previous)
        previous.update!(
          status: "active", activated_by: core_users(:super_admin), activated_at: 3.days.ago,
          submitted_by: core_users(:super_admin), submitted_at: 3.days.ago
        )
        acceptance = Legal::RecordAcceptance.call(
          subject: @organization, legal_document_version: previous_legal_version,
          accepted_by: core_users(:super_admin)
        )
        assert acceptance.success?, acceptance.error&.message

        successor_legal_version = create_published_legal_version
        previous.update!(status: "superseded")
        successor = create_version(
          schedule,
          version: 2, status: "draft", effective_from: 1.hour.ago,
          legal_document_version: successor_legal_version, acceptance_policy: "explicit",
          grandfather_until: 1.hour.from_now, supersedes_version: previous
        )
        populate_simulatable_version(successor)
        successor.update!(
          status: "active", activated_by: core_users(:super_admin), activated_at: 1.hour.ago,
          submitted_by: core_users(:super_admin), submitted_at: 1.hour.ago
        )

        grandfathered = EligibleVersion.call(organization: @organization, at: Time.current)

        assert grandfathered.success?, grandfathered.error&.message
        assert_equal previous.id, grandfathered.value.id

        expired = EligibleVersion.call(
          organization: @organization, at: successor.grandfather_until + 1.second
        )
        assert expired.failure?
        assert_equal "acceptance_required", expired.error.code
      end

      private

      def create_active_default(acceptance_policy:, effective_from: 2.days.ago)
        create_active_version(
          code: "default_#{acceptance_policy}_#{SecureRandom.hex(2)}",
          effective_from:,
          attributes: {
            schedule_type: "platform_default", acceptance_policy:,
            legal_document_version: @legal_version,
            effective_from:
          }
        )
      end
    end
  end
end
