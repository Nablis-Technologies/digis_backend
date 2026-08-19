# frozen_string_literal: true

require "test_helper"

module Ticketing
  class KeyRotationTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow(admissions_per_unit: 2) }

    test "retains the old signing key during grace and rejects it after retirement" do
      credential = @ticket.current_credential_generation.credentials.sole
      original_payload = Ticketing::Qr::Verifier.call(token: credential.qr_token).value.to_h.stringify_keys
      current_key = Rails.application.config.x.ticketing_qr_signing_keys.fetch("v1")
      activated_key = Ed25519::SigningKey.new(SecureRandom.random_bytes(32))
      rotated_payload = original_payload.merge("kid" => "v2")
      rotated_token = signed_token(rotated_payload, activated_key)

      during_grace = Ticketing::Qr::Verifier.call(
        token: rotated_token,
        verify_keys: { "v1" => current_key.verify_key, "v2" => activated_key.verify_key }
      )
      assert_predicate during_grace, :success?, during_grace.error&.message

      old_token_during_grace = Ticketing::Qr::Verifier.call(
        token: credential.qr_token,
        verify_keys: { "v1" => current_key.verify_key, "v2" => activated_key.verify_key }
      )
      assert_predicate old_token_during_grace, :success?, old_token_during_grace.error&.message

      retired = Ticketing::Qr::Verifier.call(
        token: credential.qr_token,
        verify_keys: { "v2" => activated_key.verify_key }
      )
      assert_predicate retired, :failure?
      assert_equal "unknown_qr_key", retired.error.code
    end

    test "revoked devices cannot authenticate and revocation deltas remain versioned" do
      token = SecureRandom.hex(32)
      device = Ticketing::ScannerDevice.create!(
        organization: @event.organization,
        device_identifier: "rotation-scanner-#{SecureRandom.hex(4)}",
        token_digest: Ticketing::ScannerDevice.token_digest_for(token:)
      )
      assignment = Ticketing::ScannerDeviceAssignment.create!(
        scanner_device: device, event: @event, assigned_by: @manager
      )

      authenticated = Ticketing::Scanners::Authenticate.call(
        operator: @manager, device_identifier: device.device_identifier, token:, event: @event
      )
      assert_predicate authenticated, :success?, authenticated.error&.message

      device.update!(status: "revoked", revoked_at: Time.current)
      revoked = Ticketing::Scanners::Authenticate.call(
        operator: @manager, device_identifier: device.device_identifier, token:, event: @event
      )
      assert_predicate revoked, :failure?
      assert_equal "device_inactive", revoked.error.code

      @event.update!(revocation_version: 1)
      Ticketing::Revocation.create!(
        event: @event, ticket: @ticket, revoked_through_version: 1, revocation_version: 1
      )
      delta = Ticketing::ScannerSync::BuildDelta.call(
        assignment:, cursors: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 }
      )

      assert_predicate delta, :success?, delta.error&.message
      assert_equal @ticket.id.to_s, delta.value.fetch(:package_revocations).fetch(:changed).sole.fetch(:tid)
      assert_equal 1, delta.value.fetch(:versions).fetch(:revocations)
    end

    private

    def signed_token(payload, signing_key)
      signature = signing_key.sign(Ticketing::Qr::Signer.canonical_json(payload))
      envelope = payload.merge("sig" => Base64.strict_encode64(signature))
      Base64.urlsafe_encode64(JSON.generate(envelope), padding: false)
    end
  end
end
