# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationConsentsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::ConsentTestHelpers

    setup do
      setup_consent_context
      @document, @version = create_consent_document(scope: "buyer", required: true)
      @requirement = build_consent_requirements(accept_required_buyer: false).value.first
    end

    test "registrants can list safe consent requirements without document content or evidence" do
      get "/registrations/#{@registration.id}/consents", headers: user_headers, as: :json

      assert_response :ok
      requirement = response.parsed_body.fetch("data").first
      assert_equal @requirement.id, requirement.fetch("id")
      assert_not requirement.key?("body")
      assert_not requirement.key?("content_sha256")
      assert_not requirement.key?("evidence_digest")
      assert_not requirement.key?("request_uuid")
      assert_not requirement.key?("subject_user_id")
    end

    test "a missing idempotency key blocks consent acceptance" do
      post "/registrations/#{@registration.id}/consents/#{@requirement.id}/accept",
           params: {
             request_uuid: SecureRandom.uuid,
             content_sha256: @version.content_sha256,
             acceptance_method: "otp"
           },
           headers: user_headers,
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "registrants accept a requirement through a privacy-safe command response" do
      request_uuid = SecureRandom.uuid
      params = {
        request_uuid:,
        content_sha256: @version.content_sha256,
        acceptance_method: "otp"
      }
      post "/registrations/#{@registration.id}/consents/#{@requirement.id}/accept",
           params:,
           headers: user_headers.merge("Idempotency-Key" => "consent-accept-1"),
           as: :json

      assert_response :ok
      requirement = response.parsed_body.fetch("data").fetch("requirement")
      assert_equal "accepted", requirement.fetch("status")
      assert_not response.parsed_body.fetch("data").key?("evidence_digest")
      assert_not response.parsed_body.fetch("data").key?("request_uuid")

      post "/registrations/#{@registration.id}/consents/#{@requirement.id}/accept",
           params:,
           headers: user_headers.merge("Idempotency-Key" => "consent-accept-1"),
           as: :json

      assert_response :ok
      assert_equal 1, Ticketing::RegistrationConsent.count
    end

    test "acceptance omits a pending buyer requirement from coordinate projections" do
      _document, slot_version = create_consent_document(scope: "admission_slot", required: true)
      slot_requirement = build_consent_requirements(accept_required_buyer: false).value.find do |requirement|
        requirement.acceptance_scope == "admission_slot"
      end
      slot_requirement.update!(subject_user: @actor)

      post "/registrations/#{@registration.id}/consents/#{slot_requirement.id}/accept",
           params: {
             request_uuid: SecureRandom.uuid,
             content_sha256: slot_version.content_sha256,
             acceptance_method: "otp"
           },
           headers: user_headers.merge("Idempotency-Key" => "slot-accept-with-buyer-pending"),
           as: :json

      assert_response :ok
      assert_equal "pending", response.parsed_body.dig("data", "status")
      assert_empty response.parsed_body.dig("data", "pending_coordinates")
    end

    test "an assigned admission subject can list their slot requirement" do
      _document, version = create_consent_document(scope: "admission_slot", required: true)
      slot_requirement = build_consent_requirements(accept_required_buyer: false).value.find do |requirement|
        requirement.acceptance_scope == "admission_slot"
      end
      slot_requirement.update!(subject_user: core_users(:support))
      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )

      get "/registrations/#{@registration.id}/consents",
          headers: { "Authorization" => "Bearer #{support_token}" }, as: :json

      assert_response :ok
      assert_equal slot_requirement.id, response.parsed_body.fetch("data").last.fetch("id")
      assert_equal version.version, response.parsed_body.fetch("data").last.fetch("document_version")
    end

    test "an assigned admission subject cannot list another subject's requirement" do
      @registration.update!(package_quantity: 2, party_size: 2)
      _document, version = create_consent_document(scope: "admission_slot", required: true)
      slot_requirements = build_consent_requirements(accept_required_buyer: false).value.select do |requirement|
        requirement.acceptance_scope == "admission_slot"
      end.sort_by(&:package_unit_number)
      slot_requirements.first.update!(subject_user: core_users(:support))
      slot_requirements.last.update!(subject_user: @actor)
      accept_consent(requirement: slot_requirements.last, content_sha256: version.content_sha256)

      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )

      get "/registrations/#{@registration.id}/consents",
          headers: { "Authorization" => "Bearer #{support_token}" }, as: :json

      assert_response :ok
      returned_ids = response.parsed_body.fetch("data").map { |requirement| requirement.fetch("id") }
      assert_equal [ slot_requirements.first.id ], returned_ids
      assert_equal "pending", response.parsed_body.fetch("data").first.fetch("status")
    end

    test "an assigned admission subject sees only their pending coordinate and status" do
      @registration.update!(package_quantity: 2, party_size: 2)
      _document, = create_consent_document(scope: "admission_slot", required: true)
      slot_requirements = build_consent_requirements(accept_required_buyer: false).value.select do |requirement|
        requirement.acceptance_scope == "admission_slot"
      end.sort_by(&:package_unit_number)
      slot_requirements.first.update!(subject_user: core_users(:support))
      slot_requirements.last.update!(subject_user: @actor)
      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )

      get "/registrations/#{@registration.id}/consents",
          headers: { "Authorization" => "Bearer #{support_token}" }, as: :json

      assert_response :ok
      returned = response.parsed_body.fetch("data")
      assert_equal [ slot_requirements.first.id ], returned.map { |requirement| requirement.fetch("id") }
      assert_equal [ "pending" ], returned.map { |requirement| requirement.fetch("status") }
      assert_equal [
        {
          "package_unit_number" => slot_requirements.first.package_unit_number,
          "admission_position" => slot_requirements.first.admission_position
        }
      ], returned.map { |requirement| requirement.slice("package_unit_number", "admission_position") }
    end

    test "an assigned admission subject receives only their pending coordinates after acceptance" do
      @registration.update!(package_quantity: 3, party_size: 3)
      _document, version = create_consent_document(scope: "admission_slot", required: true)
      slot_requirements = build_consent_requirements(accept_required_buyer: false).value.select do |requirement|
        requirement.acceptance_scope == "admission_slot"
      end.sort_by(&:package_unit_number)
      slot_requirements.first.update!(subject_user: core_users(:support))
      slot_requirements.drop(1).each { |requirement| requirement.update!(subject_user: @actor) }
      accept_consent(
        requirement: slot_requirements.last,
        content_sha256: version.content_sha256
      )
      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )

      post "/registrations/#{@registration.id}/consents/#{slot_requirements.first.id}/accept",
           params: {
             request_uuid: SecureRandom.uuid,
             content_sha256: version.content_sha256,
             acceptance_method: "otp"
           },
           headers: {
             "Authorization" => "Bearer #{support_token}",
             "Idempotency-Key" => "support-consent-accept"
           },
           as: :json

      assert_response :ok
      assert_equal "pending", response.parsed_body.dig("data", "status")
      assert_empty response.parsed_body.dig("data", "pending_coordinates")
    end

    test "an organizer retains full requirement visibility" do
      @registration.update!(package_quantity: 2, party_size: 2)
      _document, = create_consent_document(scope: "admission_slot", required: true)
      slot_requirements = build_consent_requirements(accept_required_buyer: false).value.select do |requirement|
        requirement.acceptance_scope == "admission_slot"
      end
      slot_requirements.first.update!(subject_user: core_users(:support))
      slot_requirements.last.update!(subject_user: @actor)

      get "/registrations/#{@registration.id}/consents", headers: owner_headers, as: :json

      assert_response :ok
      returned_ids = response.parsed_body.fetch("data").map { |requirement| requirement.fetch("id") }
      assert_equal [ @requirement.id, *slot_requirements.map(&:id) ].sort, returned_ids.sort
    end

    test "an unrelated authenticated user cannot list or accept a requirement" do
      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )
      headers = { "Authorization" => "Bearer #{support_token}" }

      get "/registrations/#{@registration.id}/consents", headers:, as: :json
      assert_response :forbidden

      post "/registrations/#{@registration.id}/consents/#{@requirement.id}/accept",
           params: {
             request_uuid: SecureRandom.uuid,
             content_sha256: @version.content_sha256,
             acceptance_method: "otp"
           },
           headers: headers.merge("Idempotency-Key" => "consent-accept-unrelated"),
           as: :json
      assert_response :forbidden
    end
  end

  class RegistrationConsentWithdrawalsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::ConsentTestHelpers

    setup do
      setup_consent_context
      _document, version = create_consent_document(scope: "admission_slot", required: false)
      @requirement = build_consent_requirements.value.first
      assign_slot!(@requirement, subject: @actor)
      @acceptance = accept_consent(requirement: @requirement, content_sha256: version.content_sha256).value
    end

    test "a missing idempotency key blocks consent withdrawal" do
      post "/registration_consents/#{@acceptance.id}/withdrawal",
           params: {}, headers: user_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "the original signer withdraws through a safe response" do
      post "/registration_consents/#{@acceptance.id}/withdrawal",
           params: { reason_code: "attendee_request" },
           headers: user_headers.merge("Idempotency-Key" => "consent-withdraw-1"),
           as: :json

      assert_response :ok
      assert_equal "complete", response.parsed_body.dig("data", "status")
      assert_not response.parsed_body.fetch("data").key?("request_uuid")
      assert_not response.parsed_body.fetch("data").key?("reason_code")
    end

    test "replaying a withdrawal returns success without duplicate history" do
      params = { reason_code: "attendee_request" }
      headers = user_headers.merge("Idempotency-Key" => "consent-withdraw-replay")

      post "/registration_consents/#{@acceptance.id}/withdrawal", params:, headers:, as: :json
      assert_response :ok

      post "/registration_consents/#{@acceptance.id}/withdrawal", params:, headers:, as: :json
      assert_response :ok
      assert_equal 1, Ticketing::RegistrationConsentWithdrawal.count
    end

    test "withdrawal omits a pending buyer requirement from coordinate projections" do
      _document, = create_consent_document(scope: "buyer", required: true)
      build_consent_requirements(accept_required_buyer: false)

      post "/registration_consents/#{@acceptance.id}/withdrawal",
           params: { reason_code: "attendee_request" },
           headers: user_headers.merge("Idempotency-Key" => "withdraw-with-buyer-pending"),
           as: :json

      assert_response :ok
      assert_equal "pending", response.parsed_body.dig("data", "status")
      assert_empty response.parsed_body.dig("data", "pending_coordinates")
    end

    test "withdrawal pending coordinates exclude another assigned subject" do
      _document, support_version = create_consent_document(scope: "admission_slot", required: false)
      support_requirement = build_consent_requirements.value.find do |requirement|
        requirement.acceptance_scope == "admission_slot" && requirement.pending?
      end
      support_requirement.update!(subject_user: core_users(:support))
      support_acceptance = accept_consent(
        requirement: support_requirement,
        actor: core_users(:support),
        content_sha256: support_version.content_sha256
      ).value
      _document, = create_consent_document(scope: "admission_slot", required: true)
      pending_requirement = build_consent_requirements.value.find do |requirement|
        requirement.acceptance_scope == "admission_slot" && requirement.pending?
      end
      pending_requirement.update!(subject_user: @actor)
      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )

      post "/registration_consents/#{support_acceptance.id}/withdrawal",
           params: { reason_code: "attendee_request" },
           headers: {
             "Authorization" => "Bearer #{support_token}",
             "Idempotency-Key" => "consent-withdraw-private"
           },
           as: :json

      assert_response :ok
      assert_empty response.parsed_body.dig("data", "pending_coordinates")
    end
  end
end
