# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    class LinksTest < ActiveSupport::TestCase
      setup do
        @campaign = Campaign.create!(
          organization: organizations_organizations(:two), created_by: core_users(:super_admin),
          name: "Link campaign #{SecureRandom.hex(4)}", channel: "email",
          timezone: "Africa/Addis_Ababa", message_body: "Hello"
        )
        Rails.application.config.x.short_links.enabled = true
      end

      teardown do
        Rails.application.config.x.short_links.enabled = false
      end

      test "creates a campaign link through the existing custom URL short-link path" do
        result = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin),
          destination_url: "https://digis.et/events/example"
        )

        assert result.success?, result.error&.message
        link = result.value
        assert_equal "https://digis.et/events/example", link.short_link.custom_url
        assert_equal @campaign.id, link.short_link.utm_campaign
        assert_equal @campaign.channel, link.short_link.utm_source
        assert_nil link.short_link.target_type
      end

      test "creates distinct short links for multiple campaign destinations" do
        first = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin),
          destination_url: "https://digis.et/events/example", name: "Tickets"
        )
        second = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin),
          destination_url: "https://digis.et/sponsors/example", name: "Sponsors"
        )

        assert first.success?, first.error&.message
        assert second.success?, second.error&.message
        refute_equal first.value.short_link.slug, second.value.short_link.slug
      end

      test "replays an existing campaign link without creating another short link" do
        first = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin),
          destination_url: "https://digis.et/events/replay", name: "Tickets"
        )
        replay = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin),
          destination_url: "https://digis.et/events/replay", name: "Tickets"
        )

        assert first.success?, first.error&.message
        assert replay.success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
        assert_equal 1, @campaign.campaign_links.count
      end

      test "keeps default-named links distinct when destinations differ" do
        first = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin), destination_url: "https://digis.et/one"
        )
        second = Messaging::Campaigns::Links::Create.call(
          campaign: @campaign, actor: core_users(:super_admin), destination_url: "https://digis.et/two"
        )

        assert first.success?, first.error&.message
        assert second.success?, second.error&.message
        refute_equal first.value.short_link.slug, second.value.short_link.slug
      end

      test "returns aggregate delivery and click counts without recipient identities" do
        result = Messaging::Campaigns::Analytics.call(campaign: @campaign)

        assert result.success?
        assert_equal 0, result.value.fetch(:sent)
        assert_equal 0, result.value.fetch(:clicks)
        refute result.value.key?(:recipient_ids)
      end

      test "loads analytics through grouped aggregate queries" do
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          statements << payload[:sql] unless payload[:name].to_s == "SCHEMA"
        end

        Messaging::Campaigns::Analytics.call(campaign: @campaign)

        assert_operator statements.length, :<=, 3
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end
  end
end
