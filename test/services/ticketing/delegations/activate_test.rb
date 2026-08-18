# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Delegations
    class ActivateTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers
      include Ticketing::ConsentTestHelpers

      setup { setup_package_workflow }

      test "replaces the group generation with one credential per assigned slot" do
        result = activate_delegated_ticket(assignments: { 1 => @recipient, 2 => nil, 3 => nil })

        assert_predicate result, :success?, result.error&.message
        assert_equal "delegated", result.value.mode
        assert_equal 2, result.value.version
        assert_equal 3, result.value.credentials.size
        assert_equal @recipient.id, credential_at(1).holder_user_id
        assert_equal "pending_claim", credential_at(2).status
        assert_equal "revoked", @ticket.reload.credential_generations.find_by(version: 1).status
      end

      test "is idempotent for the same request" do
        subject = -> { activate_delegated_ticket(key: "delegate-replay") }

        assert_idempotent(subject, counter: -> { Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count })
      end

      test "rejects an unrelated actor without changing credentials" do
        result = Ticketing::Delegations::Activate.call(
          ticket: @ticket,
          actor: @other_user,
          assignments: { 1 => @recipient, 2 => nil, 3 => nil },
          idempotency_key: "delegate-unauthorized"
        )

        assert_predicate result, :failure?
        assert_equal "delegation_forbidden", result.error.code
        assert_equal 1, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count
      end

      test "cancels delegation through a newer group generation" do
        activate_delegated_ticket

        result = Ticketing::Delegations::Cancel.call(
          ticket: @ticket,
          actor: @owner,
          idempotency_key: "delegate-cancel"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "group", result.value.mode
        assert_equal 3, result.value.version
        assert_equal "revoked", @ticket.reload.credential_generations.find_by(version: 2).status
      end

      test "reassigns one delegated slot through the replacement seam" do
        activate_delegated_ticket

        result = Ticketing::Delegations::ReassignSlot.call(
          ticket: @ticket,
          actor: @owner,
          position: 2,
          replacement_user: @other_user,
          idempotency_key: "delegate-reassign"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal 3, result.value.version
        assert_equal @other_user.id, credential_at(2).holder_user_id
      end

      test "supersedes a current personal requirement before reassigning the slot" do
        @ticket_type = @product.ticket_type
        _document, version = create_consent_document(scope: "admission_slot", required: true)
        requirement = Ticketing::RegistrationConsentRequirement.create!(
          registration: @registration,
          consent_document_version: version,
          required: true,
          acceptance_scope: "admission_slot",
          package_unit_number: 1,
          admission_position: 2,
          status: "pending",
          required_reason: "initial_submission",
          required_at: Time.current
        )
        activate_delegated_ticket

        result = Ticketing::Delegations::ReassignSlot.call(
          ticket: @ticket,
          actor: @owner,
          position: 2,
          replacement_user: @other_user,
          idempotency_key: "delegate-reassign-consent"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "superseded", requirement.reload.status
        replacement = Ticketing::RegistrationConsentRequirement.find_by!(
          supersedes_requirement_id: requirement.id
        )
        assert_equal @other_user.id, replacement.subject_user_id
        assert_equal "pending", replacement.status
        assert_equal "pending_requirements", credential_at(2).status
      end
    end
  end
end
