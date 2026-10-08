# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ScannerInvitationTest < ActiveSupport::TestCase
    test "defines the event-scoped scanner invitation model" do
      assert Ticketing.const_defined?(:ScannerInvitation, false)
    end

    test "supports only the invitation lifecycle states" do
      assert_equal %w[pending paired pairing_reset expired revoked], ScannerInvitation::STATUSES
    end

    test "encrypts invite phone and delivery link while retaining keyed digests" do
      invitation = build_invitation
      invitation.save!

      assert_equal "+251911234567", invitation.phone
      assert_equal @raw_token, invitation.token

      stored_phone = ScannerInvitation.connection.select_value(
        "SELECT phone_ciphertext FROM ticketing_scanner_invitations WHERE id = '#{invitation.id}'"
      )
      stored_token = ScannerInvitation.connection.select_value(
        "SELECT token_ciphertext FROM ticketing_scanner_invitations WHERE id = '#{invitation.id}'"
      )
      refute_includes stored_phone, "+251911234567"
      refute_includes stored_token, @raw_token
      assert_equal ScannerInvitation.phone_digest_for(
        event_id: invitation.event_id, phone: "+251911234567"
      ), invitation.phone_digest
      assert_equal ScannerInvitation.token_digest_for(token: @raw_token), invitation.token_digest
    end

    test "rejects an unsupported invitation state" do
      invitation = build_invitation(status: "accepted")
      assert_not invitation.valid?
      assert_includes invitation.errors[:status], "is not included in the list"
    end

    test "rejects malformed keyed digests" do
      malformed = build_invitation
      malformed.phone_digest = "not-a-digest"
      malformed.token_digest = "not-a-digest"
      assert_not malformed.valid?
      assert malformed.errors[:phone_digest].present?
      assert malformed.errors[:token_digest].present?
    end

    test "enforces one live invitation per event and normalized phone" do
      first = build_invitation
      first.save!

      duplicate = build_invitation(phone: "0911 23 45 67")
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:phone_digest], "has already been taken"
    end

    private

    def build_invitation(phone: "+251911234567", status: "pending")
      @raw_token ||= SecureRandom.hex(32)
      code = "482910"
      event = events_events(:ready_listing)

      ScannerInvitation.new(
        event:,
        organization: event.organization,
        created_by: core_users(:super_admin),
        phone:,
        phone_digest: ScannerInvitation.phone_digest_for(event_id: event.id, phone:),
        token: @raw_token,
        token_digest: ScannerInvitation.token_digest_for(token: @raw_token),
        pairing_code: code,
        pairing_code_digest: ScannerInvitation.pairing_code_digest_for(code:),
        create_idempotency_key_digest: SecureRandom.hex(32),
        create_request_digest: SecureRandom.hex(32),
        zone_mode: "all_current_zones",
        selected_zone_ids: [],
        status:,
        delivery_status: "queued",
        delivery_revision: 1,
        starts_at: Time.current,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        pairing_code_expires_at: 1.hour.from_now
      )
    end
  end
end
