# frozen_string_literal: true

require "test_helper"

module Commercial
  class TermNoticeTest < ActiveSupport::TestCase
    include Commercial::GovernanceTestHelpers

    setup do
      @organization = organizations_organizations(:one)
      @legal_version = create_published_legal_version
      @version = create_simulatable_version(
        code: "term_notice_model", schedule_type: "platform_default", effective_from: 2.days.from_now,
        attributes: { legal_document_version: @legal_version, acceptance_policy: "notice_only" }
      )
      @version.update!(status: "scheduled")
      @delivered_at = Time.current
    end

    test "requires exact version evidence and exposes it only to organization members" do
      notice = build_notice

      assert_predicate notice, :valid?
      assert notice.visible_to?(core_users(:super_admin))
      refute notice.visible_to?(core_users(:attendee))
    end

    test "rejects contradictory delivery metadata" do
      notice = build_notice(status: "delivered", failed_at: @delivered_at)

      assert_not notice.valid?
      assert_match(/cannot have failure evidence/, notice.errors[:failed_at].join)
    end

    test "rejects a notice whose legal version is not the fee version's legal evidence" do
      notice = build_notice(legal_document_version: create_published_legal_version)

      assert_not notice.valid?
      assert_includes notice.errors[:legal_document_version],
                      I18n.t("commercial.governance.errors.term_notice_version_mismatch")
    end

    private

    def build_notice(attributes = {})
      digest = TermNotice.evidence_digest_for(
        organization_id: @organization.id,
        fee_schedule_version_id: @version.id,
        legal_document_version_id: @legal_version.id,
        delivery_method: "in_app",
        delivered_at: @delivered_at
      )
      TermNotice.new(
        {
          organization: @organization,
          fee_schedule_version: @version,
          legal_document_version: @legal_version,
          delivery_method: "in_app",
          status: "delivered",
          evidence_digest: digest,
          available_at: @delivered_at,
          delivered_at: @delivered_at,
          idempotency_key_digest: "7" * 64
        }.merge(attributes)
      )
    end
  end
end
