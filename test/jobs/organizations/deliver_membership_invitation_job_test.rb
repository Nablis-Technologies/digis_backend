# frozen_string_literal: true

require "test_helper"

module Organizations
  class DeliverMembershipInvitationJobTest < ActiveSupport::TestCase
    setup do
      @previous_sender = Rails.application.config.x.membership_invitation_delivery_sender
      @organization = Organizations::Organization.create!(
        name: "Delivery Job #{SecureRandom.hex(5)}",
        organizer_type: "individual",
        category: "conference"
      )
      @actor = core_users(:attendee)
      @organization.memberships.create!(user: @actor, role: "owner")
      @invitation, @token = create_invitation
    end

    teardown do
      Rails.application.config.x.membership_invitation_delivery_sender = @previous_sender
    end

    test "delivers only a current pending revision and persists the provider outcome" do
      calls = []
      Rails.application.config.x.membership_invitation_delivery_sender = lambda do |**details|
        calls << details
        :delivered
      end

      Organizations::DeliverMembershipInvitationJob.perform_now(@invitation.id, 1)

      assert_equal 1, calls.size
      assert_equal "+251911999501", calls.first.fetch(:phone)
      assert_includes calls.first.fetch(:url), "#token=#{@token}"
      refute_includes calls.first.fetch(:url), "?token="
      assert_equal "membership-invitation-#{@invitation.id}-r1", calls.first.fetch(:idempotency_key)
      assert_equal "delivered", @invitation.reload.delivery_status
      assert_equal 1, @invitation.delivery_attempts
      assert_equal({
        "invitation_id" => @invitation.id,
        "delivery_revision" => 1
      }, Core::OutboxEvent.find_by!(
        event_type: "organizations.membership_invitation.delivery_requested",
        aggregate_id: @invitation.id
      ).payload)
    end

    test "records no-provider as unknown without claiming it was sent" do
      Rails.application.config.x.membership_invitation_delivery_sender = nil

      Organizations::DeliverMembershipInvitationJob.perform_now(@invitation.id, 1)

      assert_equal "unknown", @invitation.reload.delivery_status
      assert_equal 0, @invitation.delivery_attempts
      assert_nil @invitation.last_delivery_at
    end

    test "does not send a stale delivery revision after resend rotates the capability" do
      resend = Organizations::MembershipInvitations::Resend.call(
        invitation: @invitation,
        actor: @actor,
        idempotency_key: "delivery-job-resend",
        ip_address: "203.0.113.70"
      )
      assert_predicate resend, :success?, resend.error&.message
      calls = []
      Rails.application.config.x.membership_invitation_delivery_sender = ->(**details) { calls << details }

      Organizations::DeliverMembershipInvitationJob.perform_now(@invitation.id, 1)

      assert_empty calls
      assert_equal 2, @invitation.reload.delivery_revision
      assert_equal "queued", @invitation.delivery_status
      assert_equal 0, @invitation.delivery_attempts
    end

    test "marks ambiguous provider failure unknown and raises for retry" do
      Rails.application.config.x.membership_invitation_delivery_sender = ->(**_details) do
        raise Timeout::Error, "provider timed out for token #{@token}"
      end

      error = assert_raises(Core::Error) do
        Organizations::DeliverMembershipInvitationJob.new.perform(@invitation.id, 1)
      end

      refute_includes error.message, @token
      assert_equal "unknown", @invitation.reload.delivery_status
      assert_equal 1, @invitation.delivery_attempts
    end

    private

    def create_invitation
      result = Organizations::MembershipInvitations::Create.call(
        organization: @organization,
        actor: @actor,
        phone: "+251911999501",
        role: "staff",
        idempotency_key: "delivery-job-create-#{SecureRandom.hex(6)}",
        ip_address: "203.0.113.71"
      )
      assert_predicate result, :success?, result.error&.message
      [ result.value.record, result.value.token ]
    end
  end
end
