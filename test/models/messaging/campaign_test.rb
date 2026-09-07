# frozen_string_literal: true

require "test_helper"

module Messaging
  class CampaignTest < ActiveSupport::TestCase
    test "channel is immutable after creation" do
      campaign = Campaign.create!(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Immutable channel",
        channel: "sms",
        timezone: "Africa/Addis_Ababa"
      )
      campaign.channel = "email"

      refute campaign.valid?
      assert campaign.errors.details[:channel].any? { |detail| detail[:error] == :immutable }
    end

    test "rejects an invalid timezone" do
      campaign = Campaign.new(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Invalid timezone",
        channel: "sms",
        timezone: "Not/A_Timezone"
      )

      refute campaign.valid?
      assert campaign.errors[:timezone].any?
    end

    test "rejects variables outside the template allowlist" do
      campaign = Campaign.new(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Unsafe variables",
        channel: "email",
        timezone: "Africa/Addis_Ababa",
        variables: { secret: "do-not-expose" }
      )

      refute campaign.valid?
      assert campaign.errors[:variables].any?
    end

    test "exposes campaign-owned audit and allocation associations" do
      assert_equal "Messaging::CampaignAttestation", Campaign.reflect_on_association(:attestations).class_name
      assert_equal "Messaging::CampaignCreditAllocation", Campaign.reflect_on_association(:credit_allocations).class_name
      assert_equal :campaign, Campaign.reflect_on_association(:attestations).inverse_of.name
      assert_equal :campaign, Campaign.reflect_on_association(:credit_allocations).inverse_of.name
    end

    test "exposes snapshot-owned attestation association" do
      assert_equal "Messaging::CampaignAttestation",
        CampaignAudienceSnapshot.reflect_on_association(:attestations).class_name
      assert_equal :audience_snapshot,
        CampaignAudienceSnapshot.reflect_on_association(:attestations).inverse_of.name
    end
  end
end
