# frozen_string_literal: true

require "test_helper"

module Events
  class DeliverStaffInvitationJobTest < ActiveSupport::TestCase
    setup do
      @previous_sender = Rails.application.config.x.staff_invitation_delivery_sender
      @event = events_events(:ready_listing)
      @actor = core_users(:core_admin)
      @invitation, @token = create_invitation
    end

    teardown do
      Rails.application.config.x.staff_invitation_delivery_sender = @previous_sender
    end

    test "delivers only a current pending revision with a stable provider key" do
      calls = []
      Rails.application.config.x.staff_invitation_delivery_sender = lambda do |**details|
        calls << details
        :accepted
      end

      Events::DeliverStaffInvitationJob.perform_now(@invitation.id, 1)

      assert_equal 1, calls.size
      assert_equal "+251911999601", calls.first.fetch(:phone)
      assert_includes calls.first.fetch(:url), "#token=#{@token}"
      refute_includes calls.first.fetch(:url), "?token="
      assert_equal "staff-invitation-#{@invitation.id}-r1", calls.first.fetch(:idempotency_key)
      assert_equal "accepted", @invitation.reload.delivery_status
      assert_equal 1, @invitation.delivery_attempts
      assert_equal({
        "invitation_id" => @invitation.id,
        "delivery_revision" => 1
      }, Core::OutboxEvent.find_by!(
        event_type: "events.staff_invitation.delivery_requested",
        aggregate_id: @invitation.id
      ).payload)
    end

    test "records unavailable sender as unknown and not as sent" do
      Rails.application.config.x.staff_invitation_delivery_sender = nil

      Events::DeliverStaffInvitationJob.perform_now(@invitation.id, 1)

      assert_equal "unknown", @invitation.reload.delivery_status
      assert_equal 0, @invitation.delivery_attempts
      assert_nil @invitation.last_delivery_at
    end

    test "skips stale delivery revisions" do
      resend = Events::StaffInvitations::Resend.call(
        invitation: @invitation,
        actor: @actor,
        idempotency_key: "staff-delivery-resend",
        ip_address: "203.0.113.72"
      )
      assert_predicate resend, :success?, resend.error&.message
      calls = []
      Rails.application.config.x.staff_invitation_delivery_sender = ->(**details) { calls << details }

      Events::DeliverStaffInvitationJob.perform_now(@invitation.id, 1)

      assert_empty calls
      assert_equal 2, @invitation.reload.delivery_revision
      assert_equal "queued", @invitation.delivery_status
      assert_equal 0, @invitation.delivery_attempts
    end

    test "marks ambiguous provider failure unknown and raises for retry" do
      Rails.application.config.x.staff_invitation_delivery_sender = ->(**_details) do
        raise Timeout::Error, "provider timed out for token #{@token}"
      end

      error = assert_raises(Core::Error) do
        Events::DeliverStaffInvitationJob.new.perform(@invitation.id, 1)
      end

      refute_includes error.message, @token
      assert_equal "unknown", @invitation.reload.delivery_status
      assert_equal 1, @invitation.delivery_attempts
    end

    private

    def create_invitation
      result = Events::StaffInvitations::Create.call(
        event: @event,
        actor: @actor,
        phone: "+251911999601",
        role: "staff",
        idempotency_key: "staff-delivery-create-#{SecureRandom.hex(6)}",
        ip_address: "203.0.113.73"
      )
      assert_predicate result, :success?, result.error&.message
      [ result.value.record, result.value.token ]
    end
  end
end
