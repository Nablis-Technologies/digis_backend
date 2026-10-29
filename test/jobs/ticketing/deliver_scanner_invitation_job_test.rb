# frozen_string_literal: true

require "test_helper"
require "uri"

module Ticketing
  class DeliverScannerInvitationJobTest < ActiveJob::TestCase
    setup do
      @event = events_events(:ready_listing)
      @actor = core_users(:super_admin)
      result = Ticketing::Scanners::CreateInvitation.call(
        event: @event,
        actor: @actor,
        phone: "0911 23 45 67",
        starts_at: Time.current,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        idempotency_key: "delivery-invite-#{SecureRandom.hex(5)}"
      )
      raise result.error unless result.success?

      @invitation = result.value.record
      @token = result.value.token
      @revision = @invitation.delivery_revision
    end

    test "defines the scanner invitation delivery job" do
      assert Ticketing.const_defined?(:DeliverScannerInvitationJob, false)
    end

    test "decrypts recipient details only for the sender and marks provider acceptance" do
      delivery = nil
      previous_sender = Rails.application.config.x.scanner_invitation_delivery_sender
      Rails.application.config.x.scanner_invitation_delivery_sender = lambda do |phone:, url:, idempotency_key:|
        delivery = { phone:, url:, idempotency_key: }
        :accepted
      end

      Ticketing::DeliverScannerInvitationJob.perform_now(@invitation.id, @revision)

      assert_equal @invitation.phone, delivery.fetch(:phone)
      uri = URI.parse(delivery.fetch(:url))
      assert_nil uri.query
      assert_includes uri.fragment, "token=#{ERB::Util.url_encode(@token)}"
      assert_equal "scanner-invitation-#{@invitation.id}-r#{@revision}", delivery.fetch(:idempotency_key)
      assert_equal "accepted", @invitation.reload.delivery_status
      assert_equal 1, @invitation.delivery_attempts
      assert_equal({
        "invitation_id" => @invitation.id,
        "delivery_revision" => @revision
      }, Core::OutboxEvent.find_by!(
        event_type: "ticketing.scanner_invitation.delivery_requested",
        aggregate_id: @invitation.id
      ).payload)
      audit = Core::AuditLog.find_by!(auditable: @invitation, action: "ticketing.scanner_invitation.delivery_result")
      refute_includes audit.metadata.to_s, @token
      refute_includes audit.metadata.to_s, @invitation.phone
    ensure
      Rails.application.config.x.scanner_invitation_delivery_sender = previous_sender
    end

    test "ignores a stale delivery revision after resend" do
      resend = Ticketing::Scanners::ResendInvitation.call(
        invitation: @invitation,
        actor: @actor,
        idempotency_key: "delivery-resend-#{SecureRandom.hex(4)}"
      )
      assert resend.success?, resend.error&.message
      delivered = false
      previous_sender = Rails.application.config.x.scanner_invitation_delivery_sender
      Rails.application.config.x.scanner_invitation_delivery_sender = ->(**_details) { delivered = true }

      Ticketing::DeliverScannerInvitationJob.perform_now(@invitation.id, @revision)

      refute delivered
      assert_equal "queued", @invitation.reload.delivery_status
    ensure
      Rails.application.config.x.scanner_invitation_delivery_sender = previous_sender
    end

    test "marks the preview no-op sender outcome as unknown rather than sent" do
      previous_sender = Rails.application.config.x.scanner_invitation_delivery_sender
      Rails.application.config.x.scanner_invitation_delivery_sender = ->(**_details) { nil }

      Ticketing::DeliverScannerInvitationJob.perform_now(@invitation.id, @revision)

      assert_equal "unknown", @invitation.reload.delivery_status
      assert_equal 1, @invitation.delivery_attempts
    ensure
      Rails.application.config.x.scanner_invitation_delivery_sender = previous_sender
    end
  end
end
