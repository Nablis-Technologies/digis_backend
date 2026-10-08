# frozen_string_literal: true

module Ticketing
  # Creates realistic event-scoped scanner authority for service/controller
  # tests without retaining plaintext credentials in fixtures.
  module ScannerTestHelpers
    def build_scanner_assignment(event:, assigned_by:, operator: nil, device_identifier: nil, starts_at: nil,
      ends_at: nil)
      operator ||= Core::User.create!(
        email: "scanner-operator-#{SecureRandom.hex(6)}@example.com",
        phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
      )
      staff_assignment = Events::EventStaffAssignment.create!(
        event:,
        organization: event.organization,
        user: operator,
        role: "scanner",
        status: "active"
      )
      device = Ticketing::ScannerDevice.create!(
        organization: event.organization,
        device_identifier: device_identifier || "scanner-device-#{SecureRandom.hex(8)}"
      )

      Ticketing::ScannerDeviceAssignment.create!(
        scanner_device: device,
        event:,
        event_staff_assignment: staff_assignment,
        assigned_by:,
        starts_at:,
        ends_at:
      )
    end

    def pair_scanner(event:, actor:, operator: nil, phone: nil, device_name: "Test scanner")
      phone ||= operator&.phone.presence ||
        "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
      created = Ticketing::Scanners::CreateInvitation.call(
        event:,
        actor:,
        phone:,
        starts_at: 1.minute.ago,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        idempotency_key: "test-scanner-invite-#{SecureRandom.hex(8)}"
      )
      raise created.error unless created.success?

      paired = Ticketing::Scanners::PairInvitation.call(
        pairing_token: created.value.token,
        pairing_method: "sms_link",
        installation_id: "test-install-#{SecureRandom.hex(8)}",
        device_name:,
        ip_address: "203.0.113.10",
        idempotency_key: "test-scanner-pair-#{SecureRandom.hex(8)}"
      )
      raise paired.error unless paired.success?

      paired.value
    end
  end
end
