# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    module Audience
      class ResolveTest < ActiveSupport::TestCase
        include Ticketing::PackageWorkflowTestHelpers

        setup do
          setup_package_workflow(admissions_per_unit: 1)
          @organization = @event.organization
          @actor = core_users(:super_admin)
          @list = CampaignContactList.create!(
            organization: @organization,
            created_by: @actor,
            name: "Audience list #{SecureRandom.hex(4)}"
          )
          ContactLists::Append.call(
            list: @list,
            rows: [ { phone_number: @owner.phone, first_name: "Attendee" } ],
            actor: @actor,
            idempotency_key: "audience-list-#{SecureRandom.hex(4)}"
          )
        end

        test "unions and deduplicates event relationships and saved lists" do
          result = Resolve.call(
            organization: @organization,
            channel: "sms",
            sources: [
              { type: "event", event_id: @event.id, basis: "issued" },
              { type: "contact_list", id: @list.id }
            ]
          )

          assert result.success?
          assert_equal 1, result.value.length
          assert_equal expected_phone_digest, result.value.first.channel_address_digest
          assert_includes %w[event contact_list], result.value.first.source_type
        end

        test "issued and checked-in historical bases are distinct" do
          issued = Resolve.call(
            organization: @organization,
            channel: "email",
            sources: [ { type: "event", event_id: @event.id, basis: "issued" } ]
          )
          checked_in = Resolve.call(
            organization: @organization,
            channel: "email",
            sources: [ { type: "event", event_id: @event.id, basis: "checked_in" } ]
          )

          assert issued.success?
          assert checked_in.success?
          refute_equal issued.value.map(&:channel_address_digest).sort,
            checked_in.value.map(&:channel_address_digest).sort
        end

        test "resolves organization subscribers without loading users one at a time" do
          Core::Follow.create!(follower: core_users(:support), followable: @organization)

          result = Resolve.call(
            organization: @organization,
            channel: "email",
            sources: [ { type: "organization_subscribers" } ]
          )

          assert result.success?
          assert_includes result.value.map(&:channel_address_digest),
            expected_email_digest(core_users(:support).email)
        end

        private

        def expected_phone_digest
          Core::KeyedDigest.digest(
            namespace: "messaging-campaign-contact-phone",
            value: Core::PhoneIdentity::ResolveOrCreate.normalize(@owner.phone)
          )
        end

        def expected_email_digest(email)
          Core::KeyedDigest.digest(namespace: "messaging-campaign-contact-email", value: email.downcase)
        end
      end
    end
  end
end
