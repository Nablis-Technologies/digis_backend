# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    module Templates
      class RenderTest < ActiveSupport::TestCase
        setup do
          template = CampaignTemplate.create!(
            organization: organizations_organizations(:one),
            created_by: core_users(:super_admin),
            name: "Render test",
            channel: "sms"
          )
          @version = template.versions.create!(
            version: 1,
            locale: "en",
            body: "Hello {{first_name}} for {{event_name}}",
            variables: %w[first_name event_name]
          )
        end

        test "uses a neutral fallback for missing values" do
          result = Render.call(
            template_version: @version,
            channel: "sms",
            values: { event_name: "Addis Fest" }
          )

          assert result.success?
          assert_equal "Hello there for Addis Fest", result.value.body
        end

        test "keeps SMS content plain text" do
          result = Render.call(
            template_version: @version,
            channel: "sms",
            values: { first_name: "A<1>", event_name: "Fest" }
          )

          assert result.success?
          assert_equal "Hello A<1> for Fest", result.value.body
        end

        test "escapes email body content" do
          @version.campaign_template.update!(channel: "email")
          @version.body = "Hello {{first_name}}"
          @version.save!
          result = Render.call(
            template_version: @version,
            channel: "email",
            values: { first_name: "A<1>" }
          )

          assert result.success?
          assert_equal "Hello A&lt;1&gt;", result.value.body
        end

        test "uses a name fallback only for the name token" do
          @version.body = "Venue={{venue_name}} Link={{ticket_link}} Name={{first_name}}"
          @version.variables = %w[venue_name ticket_link first_name]
          @version.save!

          result = Render.call(
            template_version: @version, channel: "sms", values: { first_name: "Aster" }
          )

          assert result.success?
          assert_equal "Venue= Link= Name=Aster", result.value.body
        end
      end
    end
  end
end
