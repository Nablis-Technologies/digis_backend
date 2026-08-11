# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Consent
    class CredentialRequirementsHandoffTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup { setup_consent_context }

      test "dispatch retries the credential adapter with the same outbox identity and safe projection" do
        create_consent_document(scope: "buyer")
        build_consent_requirements(accept_required_buyer: false)
        event = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: CredentialRequirementsHandoff::EVENT_TYPE,
          aggregate: @registration,
          payload: {
            registration_id: @registration.id,
            status: "pending",
            affected_coordinates: [ { package_unit_number: 1, admission_position: 1 } ]
          },
          idempotency_key: "credential-requirements-dispatch-#{@registration.id}"
        ).value
        calls = []
        previous_adapter = Rails.application.config.x.credential_requirement_status_adapter
        Rails.application.config.x.credential_requirement_status_adapter = lambda do |**payload|
          calls << payload
          raise "simulated dispatch failure" if calls.one?
        end

        assert_equal @registration.id, event.payload.fetch("registration_id")
        assert_empty event.payload.keys & %w[consent_content evidence_digest accepted_by_user_id qr_token pnr]

        begin
          assert_raises RuntimeError, "simulated dispatch failure" do
            Core::Outbox::Dispatch.call(event_id: event.id)
          end

          assert_no_difference [
            "Ticketing::RegistrationConsentRequirement.count",
            "Ticketing::RegistrationConsent.count",
            "Core::AuditLog.count"
          ] do
            result = Core::Outbox::Dispatch.call(event_id: event.id)

            assert_predicate result, :success?
          end
        ensure
          Rails.application.config.x.credential_requirement_status_adapter = previous_adapter
        end

        event.reload
        assert_not_nil event.published_at
        assert_equal 1, event.attempts
        assert_equal "RuntimeError", event.last_error_code
        assert_equal [
          {
            event_id: event.id,
            idempotency_key: event.idempotency_key,
            registration_id: @registration.id,
            status: "pending",
            affected_coordinates: [ { "package_unit_number" => 1, "admission_position" => 1 } ]
          },
          {
            event_id: event.id,
            idempotency_key: event.idempotency_key,
            registration_id: @registration.id,
            status: "pending",
            affected_coordinates: [ { "package_unit_number" => 1, "admission_position" => 1 } ]
          }
        ], calls
      end
    end
  end
end
