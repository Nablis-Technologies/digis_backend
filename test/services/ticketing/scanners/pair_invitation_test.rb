# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class PairInvitationTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @creator = core_users(:super_admin)
        @phone = "0911 23 45 69"
        @installation_id = "pwa-install-#{SecureRandom.hex(8)}"
        @ip_address = "203.0.113.#{SecureRandom.random_number(200) + 1}"
        @invitation = create_invitation
        @token = @invitation.token
        @pairing_code = @invitation.pairing_code
      end

      test "defines the capability-based pairing command" do
        assert Scanners.const_defined?(:PairInvitation, false)
      end

      test "pairs from a high-entropy link without OTP and returns one scoped bearer" do
        result = pair(token: @token, method: "sms_link", key: "pair-sms-link")

        assert result.success?, result.error&.then { |failure| [ failure.code, failure.message, failure.errors ].inspect }
        invitation = @invitation.reload
        session = result.value.session
        operator = invitation.paired_user
        assert_equal "paired", invitation.status
        assert_equal "sms_link", invitation.pairing_method
        assert_nil operator.verified_at
        assert_empty operator.roles
        assert_equal "scanner", invitation.event_staff_assignment.role
        assert_equal "active", invitation.event_staff_assignment.status
        assert_equal @creator.id, Core::AuditLog.find_by!(
          auditable: invitation.event_staff_assignment,
          action: "event.staff.assigned_from_grant"
        ).actor_id
        assert session.active_at?
        assert_equal ScannerSession.token_digest_for(token: result.value.scanner_session_token), session.token_digest
        assert_nil invitation.token
        assert_nil invitation.pairing_code
        assert_not_includes ScannerDevice.column_names, "token_digest"
      end

      test "consumes a manual short code without OTP" do
        result = pair(code: @pairing_code, method: "short_code", key: "pair-code")

        assert result.success?, result.error&.then { |failure| [ failure.code, failure.message, failure.errors ].inspect }
        assert_equal "paired", @invitation.reload.status
        assert_equal "short_code", @invitation.pairing_method
        assert result.value.scanner_session_token.present?
      end

      test "all-current-zones access snapshots active zones at pairing time" do
        active = create_zone("Main Gate")
        inactive = create_zone("Closed Gate", active: false)

        result = pair(token: @token, method: "organizer_qr", key: "pair-all-zones")

        assert result.success?, result.error&.message
        assert_equal [ active.id ], result.value.session.scanner_device_assignment.access_zones.pluck(:id)
        refute_includes result.value.session.scanner_device_assignment.access_zones.pluck(:id), inactive.id
      end

      test "selected zones are exact and an empty selected scope grants no access" do
        selected = create_zone("VIP Gate")
        unselected = create_zone("Main Gate")
        @invitation.update!(zone_mode: "selected_zones", selected_zone_ids: [ selected.id ])

        selected_result = pair(token: @token, method: "organizer_qr", key: "pair-selected-zone")

        assert selected_result.success?, selected_result.error&.message
        assert_equal [ selected.id ],
          selected_result.value.session.scanner_device_assignment.access_zones.pluck(:id)
        refute_includes selected_result.value.session.scanner_device_assignment.access_zones.pluck(:id), unselected.id

        another = create_invitation(phone: "0911 23 45 71")
        another.update!(zone_mode: "selected_zones", selected_zone_ids: [])
        empty_result = PairInvitation.call(
          pairing_token: another.token,
          pairing_method: "organizer_qr",
          installation_id: "empty-scope-install-#{SecureRandom.hex(5)}",
          ip_address: @ip_address,
          idempotency_key: "pair-empty-scope"
        )

        assert empty_result.success?, empty_result.error&.message
        assert_empty empty_result.value.session.scanner_device_assignment.access_zones
      end

      test "keeps an invitation valid when its original manager loses role after issuance" do
        manager = Core::User.create!(
          email: "durable-grant-#{SecureRandom.hex(5)}@example.com",
          phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        )
        manager_assignment = Events::EventStaffAssignment.create!(
          event: @event,
          organization: @event.organization,
          user: manager,
          role: "manager",
          status: "active"
        )
        invitation = create_invitation(phone: "0911 23 45 70", actor: manager)
        manager_assignment.update!(status: "revoked")

        result = PairInvitation.call(
          pairing_token: invitation.token,
          pairing_method: "organizer_qr",
          installation_id: @installation_id,
          device_name: "Gate tablet",
          ip_address: @ip_address,
          idempotency_key: "pair-durable-event-grant"
        )

        assert result.success?, result.error&.then { |failure| [ failure.code, failure.message, failure.errors ].inspect }
        assert_equal "scanner", invitation.reload.event_staff_assignment.role
        assert_equal manager.id, Core::AuditLog.find_by!(
          auditable: invitation.event_staff_assignment,
          action: "event.staff.assigned_from_grant"
        ).actor_id
      end

      test "replays the exact pairing key without minting or returning another session token" do
        first = pair(token: @token, method: "sms_link", key: "pair-replay")
        second = pair(token: @token, method: "sms_link", key: "pair-replay")

        assert first.success?, first.error&.then { |failure| [ failure.code, failure.message, failure.errors ].inspect }
        assert second.success?, second.error&.then { |failure| [ failure.code, failure.message, failure.errors ].inspect }
        assert second.value.replayed?
        assert_nil second.value.scanner_session_token
        assert_equal 1, ScannerSession.where(scanner_invitation: @invitation).count
      end

      test "rejects a reused key with changed installation identity" do
        first = pair(token: @token, method: "sms_link", key: "pair-conflict")
        second = PairInvitation.call(
          pairing_token: @token,
          pairing_method: "sms_link",
          installation_id: "another-installation-#{SecureRandom.hex(4)}",
          device_name: "Another phone",
          ip_address: @ip_address,
          idempotency_key: "pair-conflict"
        )

        assert first.success?, first.error&.then { |failure| [ failure.code, failure.message, failure.errors ].inspect }
        assert_equal "idempotency_conflict", second.error.code
      end

      test "rejects a short code after its code deadline and a link after invitation expiry" do
        @invitation.update!(pairing_code_expires_at: 1.minute.ago)
        expired_code = pair(code: @pairing_code, method: "short_code", key: "expired-code")
        assert_equal "pairing_invalid", expired_code.error.code

        expired_invitation = create_invitation(phone: "0911 23 45 72")
        expired_invitation.update!(
          expires_at: 1.minute.ago,
          pairing_code_expires_at: 2.minutes.ago
        )
        expired_link = PairInvitation.call(
          pairing_token: expired_invitation.token,
          pairing_method: "sms_link",
          installation_id: "expired-install-#{SecureRandom.hex(5)}",
          ip_address: @ip_address,
          idempotency_key: "expired-link"
        )
        assert_equal "pairing_invalid", expired_link.error.code
      end

      test "limits short-code attempts per installation and invalidates expired and revoked material" do
        cache = ActiveSupport::Cache::MemoryStore.new
        Prosopite.pause do
          3.times do |index|
            result = pair(code: "00000#{index}", method: "short_code", key: "bad-code-#{index}", cache:)
            assert_equal "pairing_invalid", result.error.code
          end
          throttled = pair(code: @pairing_code, method: "short_code", key: "code-after-limit", cache:)
          assert_equal "pairing_rate_limited", throttled.error.code
        end

        @invitation.update!(status: "revoked", token_ciphertext: nil, pairing_code_ciphertext: nil,
                            revoked_at: Time.current)
        invalidated = pair(token: @token, method: "sms_link", key: "revoked-token")
        assert_equal "pairing_invalid", invalidated.error.code
      end

      test "limits short-code attempts across installations sharing one source IP" do
        cache = ActiveSupport::Cache::MemoryStore.new
        Prosopite.pause do
          30.times do |index|
            result = pair(
              code: "000001",
              method: "short_code",
              key: "ip-code-attempt-#{index}",
              installation_id: "separate-install-#{SecureRandom.hex(6)}",
              cache:
            )
            assert_equal "pairing_invalid", result.error.code
          end
          limited = pair(
            code: @pairing_code,
            method: "short_code",
            key: "ip-code-attempt-limited",
            installation_id: "final-install-#{SecureRandom.hex(6)}",
            cache:
          )
          assert_equal "pairing_rate_limited", limited.error.code
        end
      end

      private

      def create_invitation(phone: @phone, actor: @creator)
        result = Ticketing::Scanners::CreateInvitation.call(
          event: @event,
          actor:,
          phone:,
          starts_at: Time.current,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "pair-source-#{SecureRandom.hex(5)}"
        )
        raise result.error unless result.success?

        result.value.record
      end

      def pair(token: nil, code: nil, method:, key:, installation_id: @installation_id, cache: Rails.cache)
        PairInvitation.call(
          pairing_token: token,
          pairing_code: code,
          pairing_method: method,
          installation_id:,
          device_name: "Scanner phone",
          ip_address: @ip_address,
          idempotency_key: key,
          cache:
        )
      end

      def create_zone(name, active: true)
        date = @event.event_dates.where(status: "scheduled").first
        @event.access_zones.create!(
          event_date: date,
          type: "venue",
          name: "#{name} #{SecureRandom.hex(3)}",
          code: "#{name.parameterize}-#{SecureRandom.hex(3)}",
          active:
        )
      end
    end
  end
end
