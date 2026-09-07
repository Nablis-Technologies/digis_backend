# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class PrepareCampaignAudienceJobTest < ActiveJob::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    test "writes recipients in bounded batches and marks the snapshot ready" do
      setup_package_workflow(admissions_per_unit: 1)
      actor = core_users(:super_admin)
      campaign = Campaign.create!(
        organization: @event.organization,
        created_by: actor,
        name: "Batch snapshot #{SecureRandom.hex(4)}",
        channel: "email",
        timezone: "Africa/Addis_Ababa",
        message_body: "Hello",
        metadata: { "audience_sources" => [ { "type" => "event", "event_id" => @event.id,
                                              "basis" => "issued" } ] }
      )
      snapshot = CampaignAudienceSnapshot.create!(
        campaign:,
        source_spec: { "sources" => campaign.metadata.fetch("audience_sources") },
        status: "preparing",
        started_at: Time.current
      )

      PrepareCampaignAudienceJob.perform_now(snapshot.id)

      snapshot.reload
      assert_equal "ready", snapshot.status
      assert_equal snapshot.total_count, snapshot.processed_count
      assert_equal 1, snapshot.recipients.count
      assert_operator snapshot.eligible_quantity, :>, 0
    end

    test "quotes the rendered campaign context instead of the fallback token" do
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      list = CampaignContactList.create!(
        organization:, created_by: actor, name: "Context list #{SecureRandom.hex(4)}"
      )
      append = Campaigns::ContactLists::Append.call(
        list:, rows: [ { phone_number: "+251911987654" } ], actor:,
        idempotency_key: "context-list-#{SecureRandom.hex(4)}"
      )
      assert append.success?, append.error&.message
      campaign = Campaign.create!(
        organization:, created_by: actor, name: "Context campaign #{SecureRandom.hex(4)}", channel: "sms",
        timezone: "Africa/Addis_Ababa", message_body: "x" * 150 + " {{organization_name}}"
      )
      snapshot = CampaignAudienceSnapshot.create!(
        campaign:, source_spec: { "sources" => [ { "type" => "contact_list", "id" => list.id } ] },
        status: "preparing", started_at: Time.current
      )

      PrepareCampaignAudienceJob.perform_now(snapshot.id)

      recipient = snapshot.reload.recipients.first
      assert_equal 2, recipient.quantity
      assert_equal 2, snapshot.eligible_quantity
    end

    test "looks up suppressions once per candidate batch" do
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      list = CampaignContactList.create!(
        organization:, created_by: actor, name: "Suppression batches #{SecureRandom.hex(4)}"
      )
      rows = 501.times.map { |index| { phone_number: "+251911#{format("%06d", index + 1)}" } }
      append = Campaigns::ContactLists::Append.call(
        list:, rows:, actor:, idempotency_key: "suppression-batches-#{SecureRandom.hex(4)}"
      )
      assert append.success?, append.error&.message
      campaign = Campaign.create!(
        organization:, created_by: actor, name: "Suppression batches #{SecureRandom.hex(4)}", channel: "sms",
        timezone: "Africa/Addis_Ababa", message_body: "Hello",
        metadata: { "audience_sources" => [ { "type" => "contact_list", "id" => list.id } ] }
      )
      snapshot = CampaignAudienceSnapshot.create!(
        campaign:, source_spec: { "sources" => campaign.metadata.fetch("audience_sources") },
        status: "preparing", started_at: Time.current
      )
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        statements << payload[:sql] if payload[:sql].to_s.include?("messaging_campaign_suppressions")
      end

      PrepareCampaignAudienceJob.perform_now(snapshot.id)

      assert_operator statements.length, :>=, 2
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
