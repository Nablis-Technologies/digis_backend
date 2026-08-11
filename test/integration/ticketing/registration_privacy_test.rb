# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationPrivacyTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::ConsentTestHelpers
    include Ticketing::AttendeeExportTestHelpers

    setup do
      setup_consent_context
      @document, @version = create_consent_document(scope: "buyer", required: true)
      @requirement = build_consent_requirements(accept_required_buyer: false).value.first
      @export = create_export(event: @event, actor: core_users(:super_admin))
    end

    test "registration, consent, and export responses omit private payloads" do
      get "/registrations/#{@registration.id}", headers: user_headers, as: :json
      assert_response :success
      assert_safe_payload(response.parsed_body)

      get "/registrations/#{@registration.id}/consents", headers: user_headers, as: :json
      assert_response :success
      assert_safe_payload(response.parsed_body)

      get "/attendee_exports/#{@export.id}", headers: admin_headers, as: :json
      assert_response :success
      assert_safe_payload(response.parsed_body)
    end

    test "public consent discovery exposes content but never acceptance evidence" do
      @event.update_columns(status: "published", visibility: "public")
      @ticket_type.event_product.update!(status: "active")

      get "/public/events/#{@event.slug}/ticket_types/#{@ticket_type.id}/consent_requirements", as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert data.any?
      data.each do |requirement|
        assert_not requirement.key?("evidence_digest")
        assert_not requirement.key?("request_uuid")
        assert_not requirement.key?("subject_user_id")
      end
    end

    private

    def assert_safe_payload(payload)
      serialized = JSON.generate(payload)
      %w[
        answer answer_ciphertext evidence_digest request_uuid field_keys filters
        identity_digest token_digest session_jti_digest
      ].each do |secret|
        assert_not_includes serialized, secret
      end
    end
  end
end
