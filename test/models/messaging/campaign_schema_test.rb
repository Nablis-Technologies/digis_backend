# frozen_string_literal: true

require "test_helper"

module Messaging
  class CampaignSchemaTest < ActiveSupport::TestCase
    test "credit reservations accept campaign and campaign-recipient sources" do
      assert_includes CreditReservation::SOURCE_TYPES, "Messaging::Campaign"
      assert_includes CreditReservation::SOURCE_TYPES, "Messaging::CampaignRecipient"
    end

    test "campaign exposes launch version and complete quote fields" do
      campaign = Campaign.new(timezone: "Africa/Addis_Ababa")

      assert_equal 1, campaign.launch_version
      %i[quoted_rate_version_id quoted_quantity quote_digest quoted_at quote_expires_at].each do |field|
        assert_respond_to campaign, field
      end
      assert_respond_to campaign, :quoted_unit_price_minor
    end

    test "campaign recipient deduplication is database enforced" do
      campaign = Campaign.create!(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Schema campaign",
        channel: "sms",
        timezone: "Africa/Addis_Ababa"
      )
      snapshot = CampaignAudienceSnapshot.create!(campaign:, source_spec: {})
      first = CampaignRecipient.create!(
        campaign:, audience_snapshot: snapshot,
        channel: "sms",
        channel_address_digest: "a" * 64,
        channel_address_ciphertext: "encrypted-a",
        source_type: "contact_list",
        eligibility_status: "eligible",
        quantity: 1
      )
      duplicate = first.dup

      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "suppression supports global and organization scopes" do
      assert CampaignSuppression.new(
        channel: "sms", channel_address_digest: "b" * 64, source: "provider",
        reason: "stop", suppressed_at: Time.current,
        idempotency_key_digest: "d" * 64
      ).valid?
      assert CampaignSuppression.new(
        organization: organizations_organizations(:one), channel: "sms",
        channel_address_digest: "c" * 64, source: "organizer",
        reason: "unsubscribe", suppressed_at: Time.current,
        idempotency_key_digest: "e" * 64
      ).valid?
    end
  end
end
