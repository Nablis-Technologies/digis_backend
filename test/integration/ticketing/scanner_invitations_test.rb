# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ScannerInvitationsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @actor = core_users(:core_admin)
      @payload = {
        scanner_invitation: {
          phone: "0911 23 45 67",
          display_label: "Abel - Main Gate",
          note: "Main entrance",
          zone_mode: "all_current_zones",
          zone_ids: [],
          starts_at: 1.hour.ago.iso8601,
          ends_at: 3.days.from_now.iso8601,
          expires_at: 2.days.from_now.iso8601
        }
      }
    end

    test "owner creates a phone invitation and receives no-store one-time pairing material" do
      assert_difference -> { Ticketing::ScannerInvitation.count }, 1 do
        post "/events/#{@event.id}/scanner_invitations",
             params: @payload,
             headers: owner_headers.merge("Idempotency-Key" => "scanner-invite-create"),
             as: :json
      end

      assert_response :created
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
      data = response.parsed_body.fetch("data")
      invitation = Ticketing::ScannerInvitation.find(data.dig("scanner_invitation", "id"))
      assert_equal "pending", invitation.status
      assert_equal "+251911234567", invitation.phone
      assert_equal invitation.id, data.dig("scanner_invitation", "id")
      assert_match(/\A[0-9a-f]{64}\z/, data.dig("pairing_material", "token"))
      assert_match(/\A\d{6}\z/, data.dig("pairing_material", "pairing_code"))
      pairing_url = data.dig("pairing_material", "pairing_url")
      assert_match(%r{\Ahttps?://[^#]+/pair#}, pairing_url)
      assert_includes pairing_url.split("#", 2).last, "token=#{data.dig("pairing_material", "token")}"
      refute_includes pairing_url, "?"
      refute_includes response.body, "+251911234567"
      refute_includes response.body, "token_digest"
      assert_empty @event.event_staff_assignments.where(role: "scanner")
      assert_empty Ticketing::ScannerDevice.where(organization: @event.organization)
    end

    test "replaying create returns the same still-valid pairing material without duplicate writes" do
      headers = owner_headers.merge("Idempotency-Key" => "scanner-invite-replay")
      post "/events/#{@event.id}/scanner_invitations", params: @payload, headers:, as: :json
      assert_response :created
      original = response.parsed_body.fetch("data")

      assert_no_difference -> { Ticketing::ScannerInvitation.count } do
        assert_no_difference -> { Core::OutboxEvent.where(
          event_type: "ticketing.scanner_invitation.delivery_requested"
        ).count } do
          post "/events/#{@event.id}/scanner_invitations", params: @payload, headers:, as: :json
        end
      end

      assert_response :ok
      replay = response.parsed_body.fetch("data")
      assert_equal original.dig("scanner_invitation", "id"), replay.dig("scanner_invitation", "id")
      assert_equal original.dig("pairing_material", "token"), replay.dig("pairing_material", "token")
      assert_equal original.dig("pairing_material", "pairing_code"), replay.dig("pairing_material", "pairing_code")
      assert_equal true, replay.fetch("replayed")
    end

    test "requires idempotency key and denies an attendee" do
      post "/events/#{@event.id}/scanner_invitations", params: @payload, headers: owner_headers, as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")

      post "/events/#{@event.id}/scanner_invitations",
           params: @payload,
           headers: user_headers.merge("Idempotency-Key" => "scanner-invite-forbidden"),
           as: :json
      assert_response :forbidden
    end

    test "owner can resend and replay without rotating twice" do
      invitation_id = create_invite
      headers = owner_headers.merge("Idempotency-Key" => "scanner-invite-resend")

      post "/scanner_invitations/#{invitation_id}/resend", headers:, as: :json

      assert_response :ok
      first = response.parsed_body.fetch("data")
      assert_equal 2, first.dig("scanner_invitation", "delivery_revision")
      assert_match(/\A[0-9a-f]{64}\z/, first.dig("pairing_material", "token"))
      assert_match(/\A\d{6}\z/, first.dig("pairing_material", "pairing_code"))

      post "/scanner_invitations/#{invitation_id}/resend", headers:, as: :json

      assert_response :ok
      replay = response.parsed_body.fetch("data")
      assert_equal true, replay.fetch("replayed")
      assert_nil replay.dig("pairing_material", "token")
      assert_nil replay.dig("pairing_material", "pairing_code")
      assert_equal 2, response.parsed_body.dig("data", "scanner_invitation", "delivery_revision")
    end

    test "owner can revoke a pending invite and cannot address another event's invitation" do
      invitation_id = create_invite
      post "/scanner_invitations/#{invitation_id}/revoke",
           headers: owner_headers.merge("Idempotency-Key" => "scanner-invite-revoke"),
           as: :json

      assert_response :ok
      assert_equal "revoked", response.parsed_body.dig("data", "scanner_invitation", "status")
      assert_nil response.parsed_body.dig("data", "pairing_material")

      other_event_invitation = create_invite(event: events_events(:draft_concert))
      post "/scanner_invitations/#{other_event_invitation}/revoke",
           headers: user_headers.merge("Idempotency-Key" => "scanner-cross-event"),
           as: :json
      assert_response :not_found
    end

    test "resend requires an idempotency key" do
      invitation_id = create_invite
      post "/scanner_invitations/#{invitation_id}/resend", headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "roster returns pending invitations and paired assignments as safe projections" do
      pending_id = create_invite
      paired_id = create_invite(phone: "0911 23 45 68")
      paired_invitation = Ticketing::ScannerInvitation.find(paired_id)
      assignment = pair_invitation(paired_invitation)

      get "/events/#{@event.id}/scanners", headers: owner_headers, as: :json

      assert_response :ok
      data = response.parsed_body.fetch("data")
      pending = data.fetch("invitations").find { |row| row.fetch("id") == pending_id }
      paired = data.fetch("assignments").find { |row| row.fetch("id") == assignment.id }
      assert_equal "pending", pending.fetch("status")
      assert_equal "+25191***67", pending.fetch("masked_phone")
      assert_equal "paired", paired.fetch("invitation_status")
      assert_equal 0, paired.fetch("scan_count")
      refute_includes response.body, paired_invitation.phone
      refute_includes response.body, paired_invitation.token_digest
      refute_includes response.body, "pairing_code_digest"
      assert_includes response.body, "Main entrance"
    end

    test "roster is restricted to event scanner managers" do
      get "/events/#{@event.id}/scanners", headers: user_headers, as: :json

      assert_response :forbidden
    end

    test "manager updates paired scanner scope and advances the offline schedule cursor" do
      invitation_id = create_invite
      assignment = pair_invitation(Ticketing::ScannerInvitation.find(invitation_id))
      zone = create_zone("VIP")
      previous_version = @event.reload.schedule_version
      params = {
        scanner_device_assignment: {
          zone_mode: "selected_zones",
          zone_ids: [ zone.id ],
          starts_at: 1.hour.ago.iso8601,
          ends_at: 4.days.from_now.iso8601
        }
      }

      patch "/events/#{@event.id}/scanner_device_assignments/#{assignment.id}",
            params:,
            headers: owner_headers.merge("Idempotency-Key" => "scanner-scope-update"),
            as: :json

      assert_response :ok
      assert_equal previous_version + 1, @event.reload.schedule_version
      assert_equal [ zone.id ], assignment.reload.assignment_zones.pluck(:access_zone_id)
      assert_equal [ zone.id ], response.parsed_body.dig("data", "zones").map { |item| item.fetch("id") }
    end

    test "scope updates require an idempotency key and reject unauthorized actors" do
      invitation_id = create_invite
      assignment = pair_invitation(Ticketing::ScannerInvitation.find(invitation_id))

      patch "/events/#{@event.id}/scanner_device_assignments/#{assignment.id}",
            params: { scanner_device_assignment: { zone_mode: "selected_zones", zone_ids: [] } },
            headers: owner_headers,
            as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")

      patch "/events/#{@event.id}/scanner_device_assignments/#{assignment.id}",
            params: { scanner_device_assignment: { zone_mode: "selected_zones", zone_ids: [] } },
            headers: user_headers.merge("Idempotency-Key" => "scanner-scope-forbidden"),
            as: :json
      assert_response :forbidden
    end

    private

    def create_invite(event: @event, phone: "0911 23 45 67")
      result = Ticketing::Scanners::CreateInvitation.call(
        event:,
        actor: @actor,
        phone:,
        label: "Abel - Main Gate",
        note: "Main entrance",
        starts_at: 1.hour.ago,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        idempotency_key: "integration-invite-#{SecureRandom.hex(5)}"
      )
      raise result.error unless result.success?

      result.value.record.id
    end

    def pair_invitation(invitation)
      operator = Core::User.create!(
        email: "roster-operator-#{SecureRandom.hex(5)}@example.com",
        phone: invitation.phone
      )
      staff_assignment = Events::EventStaffAssignment.create!(
        event: @event,
        organization: @event.organization,
        user: operator,
        role: "scanner",
        status: "active"
      )
      device = Ticketing::ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "roster-device-#{SecureRandom.hex(5)}"
      )
      device_assignment = Ticketing::ScannerDeviceAssignment.create!(
        scanner_device: device,
        event: @event,
        event_staff_assignment: staff_assignment,
        assigned_by: @actor,
        starts_at: Time.current,
        ends_at: 3.days.from_now
      )
      invitation.update!(
        status: "paired",
        paired_user: operator,
        event_staff_assignment: staff_assignment,
        scanner_device: device,
        scanner_device_assignment: device_assignment,
        paired_at: Time.current,
        pairing_method: "sms_link"
      )
      Ticketing::ScannerSession.create!(
        scanner_invitation: invitation,
        scanner_device_assignment: device_assignment,
        token_digest: Ticketing::ScannerSession.token_digest_for(token: SecureRandom.hex(32)),
        idempotency_key_digest: SecureRandom.hex(32),
        request_digest: SecureRandom.hex(32),
        expires_at: 2.days.from_now
      )
      device_assignment
    end

    def create_zone(name)
      @event.access_zones.create!(
        event_date: @event.event_dates.where(status: "scheduled").first,
        type: "venue",
        name: "#{name} #{SecureRandom.hex(3)}",
        code: "#{name.downcase}-#{SecureRandom.hex(3)}"
      )
    end
  end
end
