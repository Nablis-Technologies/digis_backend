# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    class AttestTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:two)
        @actor = core_users(:super_admin)
        @campaign = Campaign.create!(
          organization: @organization,
          created_by: @actor,
          name: "Attestation #{SecureRandom.hex(4)}",
          channel: "sms",
          timezone: "Africa/Addis_Ababa",
          message_body: "Hello"
        )
        @snapshot = CampaignAudienceSnapshot.create!(
          campaign: @campaign,
          source_spec: { "sources" => [] },
          status: "ready",
          completed_at: Time.current
        )
      end

      test "requires explicit confirmation and records an idempotent attestation" do
        missing = Attest.call(
          campaign: @campaign, audience_snapshot: @snapshot, actor: @actor,
          channel: "sms", historical_basis: "issued", confirmation: false,
          idempotency_key: "attest-missing"
        )
        assert_equal "campaign_attestation_confirmation_required", missing.error.code

        operation = -> {
          Attest.call(
            campaign: @campaign, audience_snapshot: @snapshot, actor: @actor,
            channel: "sms", historical_basis: "issued", confirmation: true,
            idempotency_key: "attest-replay"
          )
        }
        assert_idempotent(operation, counter: -> { CampaignAttestation.count })
        attestation = operation.call.value
        assert_equal @snapshot.id, attestation.audience_snapshot_id
        assert_equal "issued", attestation.historical_basis
      end

      test "rejects an actor who cannot administer the organization" do
        result = Attest.call(
          campaign: @campaign, audience_snapshot: @snapshot, actor: core_users(:attendee),
          channel: "sms", confirmation: true, idempotency_key: "attest-forbidden"
        )

        assert_equal "unauthorized", result.error.code
      end
    end
  end
end
