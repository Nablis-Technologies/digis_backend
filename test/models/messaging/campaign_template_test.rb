# frozen_string_literal: true

require "test_helper"

module Messaging
  class CampaignTemplateTest < ActiveSupport::TestCase
    setup do
      @template = CampaignTemplate.create!(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Welcome",
        channel: "sms"
      )
    end

    test "rejects variables outside the campaign allowlist" do
      version = @template.versions.build(
        version: 1,
        locale: "en",
        body: "Hello {{unknown_variable}}",
        variables: [ "unknown_variable" ]
      )

      refute version.valid?
      assert version.errors.details[:body].any? { |detail| detail[:error] == :unknown_variable }
    end

    test "stores template body encrypted at rest" do
      version = @template.versions.create!(
        version: 1,
        locale: "en",
        body: "Hello {{first_name}}",
        variables: [ "first_name" ]
      )

      assert_equal "Hello {{first_name}}", version.body
      refute_equal "Hello {{first_name}}", version.attributes_before_type_cast.fetch("body_ciphertext")
    end

    test "requires every template variable to be declared" do
      version = @template.versions.build(
        version: 2,
        locale: "en",
        body: "Hello {{first_name}}",
        variables: []
      )

      refute version.valid?
      assert version.errors.details[:variables].any? { |detail| detail[:error] == :undeclared_variable }
    end
  end
end
