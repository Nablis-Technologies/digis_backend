# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationConsentTest < ActiveSupport::TestCase
    include Ticketing::ConsentTestHelpers

    setup { setup_consent_context }

    test "acceptance and withdrawal evidence cannot be edited or deleted" do
      _document, version = create_consent_document(scope: "admission_slot", required: false)
      requirement = build_consent_requirements.value.first
      assign_slot!(requirement, subject: @actor)
      acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value
      Ticketing::Consent::Withdraw.call(
        consent: acceptance,
        actor: @actor,
        idempotency_key: "immutable-withdrawal"
      )
      withdrawal = acceptance.reload.withdrawal

      assert_raises(ActiveRecord::ReadOnlyRecord) { acceptance.update!(evidence_digest: "f" * 64) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { withdrawal.update!(reason_code: "privacy_request") }
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.where(id: acceptance.id).update_all(accepted_at: 1.day.ago)
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.lease_connection.execute(
          "DELETE FROM ticketing_registration_consent_withdrawals WHERE id = '#{withdrawal.id}'"
        )
      end
    end

    test "acceptance stores only the keyed idempotency digest" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      key = "private-acceptance-key"
      acceptance = accept_consent(
        requirement:,
        content_sha256: version.content_sha256,
        idempotency_key: key
      ).value

      assert_equal Core::KeyedDigest.digest(
        namespace: "ticketing-consent-accept", value: key
      ), acceptance.idempotency_key_digest
      assert_not_equal key, acceptance.idempotency_key_digest
      assert_not_includes Ticketing::RegistrationConsent.ransackable_attributes, "idempotency_key_digest"
    end

    test "model rejects evidence that does not derive from its stored acceptance fields" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      accepted_at = Time.current
      consent = Ticketing::RegistrationConsent.new(
        registration_consent_requirement: requirement,
        registration: @registration,
        accepted_by_user: @actor,
        signer_role: "buyer",
        acceptance_method: "otp",
        content_sha256: version.content_sha256,
        evidence_digest: "f" * 64,
        idempotency_key_digest: "a" * 64,
        request_uuid: SecureRandom.uuid,
        retention_policy: @retention_policy,
        retain_until: accepted_at + 30.days,
        accepted_at:
      )

      assert_not consent.valid?
      assert consent.errors[:evidence_digest].present?
    end

    test "database rejects forged evidence and invalid retention snapshots" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) do
          insert_consent!(requirement:, version:, evidence_digest: "f" * 64)
        end
      end

      inactive_policy = Core::DataRetentionPolicy.create!(
        category: "consent_evidence",
        version: 2,
        retention_days: 30,
        action: "erase_payload",
        status: "draft",
        created_by: core_users(:super_admin)
      )
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) do
          insert_consent!(requirement:, version:, retention_policy: inactive_policy)
        end
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) do
          insert_consent!(requirement:, version:, retain_until: 31.days.from_now)
        end
      end
    end

    test "deferred integrity rejects direct evidence when its requirement remains pending" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first

      assert_raises(ActiveRecord::CheckViolation) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) do
          insert_consent!(requirement:, version:)
          Ticketing::RegistrationConsent.connection.execute(<<~SQL)
            SET CONSTRAINTS
              trg_consent_evidence_requirement_accepted
              IMMEDIATE
          SQL
        end
      end
    end

    test "accept service keeps evidence insertion before the accepted requirement transition" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first

      Ticketing::RegistrationConsent.transaction(requires_new: true) do
        result = accept_consent(requirement:, content_sha256: version.content_sha256)

        assert_predicate result, :success?
        Ticketing::RegistrationConsent.connection.execute(<<~SQL)
          SET CONSTRAINTS
            trg_consent_evidence_requirement_accepted,
            trg_consent_requirement_has_evidence
            IMMEDIATE
        SQL
      end
    end

    test "database rejects self-consistent evidence from an unverified signer" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      @actor.update_column(:verified_at, nil)

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) do
          insert_consent!(requirement:, version:)
        end
      end
    end

    test "model rejects payload erasure before its retention deadline" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

      acceptance.assign_attributes(
        accepted_by_user_id: nil,
        evidence_digest: nil,
        request_uuid: nil,
        idempotency_key_digest: nil,
        erased_at: Time.current
      )

      assert_not acceptance.valid?
      assert acceptance.errors[:erased_at].present?
    end

    test "database rejects payload erasure before its retention deadline" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) { erase_payload!(acceptance) }
      end
      assert_nil acceptance.reload.erased_at
    end

    test "database rejects payload erasure covered by an active consent evidence hold" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = due_consent!(requirement:, version:)
      Core::DataRetentionHold.create!(
        registration: @registration,
        category: "consent_evidence",
        reason_code: "legal_hold",
        placed_by: core_users(:super_admin),
        starts_at: 1.minute.ago,
        idempotency_key: SecureRandom.uuid
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) { erase_payload!(acceptance) }
      end
      assert_nil acceptance.reload.erased_at
    end

    test "database evaluates payload-erasure holds at wall-clock time" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = due_consent!(requirement:, version:)

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.transaction(requires_new: true) do
          transaction_started_at = Ticketing::RegistrationConsent.connection.select_value("SELECT CURRENT_TIMESTAMP").to_time
          starts_at = 0.2.seconds.from_now
          assert_operator transaction_started_at, :<, starts_at
          Core::DataRetentionHold.create!(
            registration: @registration,
            category: "consent_evidence",
            reason_code: "legal_hold",
            placed_by: core_users(:super_admin),
            starts_at:,
            idempotency_key: SecureRandom.uuid
          )

          Ticketing::RegistrationConsent.connection.execute("SELECT pg_sleep(0.3)")
          wall_time = Ticketing::RegistrationConsent.connection.select_value("SELECT clock_timestamp()").to_time
          assert_operator wall_time, :>=, starts_at

          erase_payload!(acceptance)
        end
      end
      assert_nil acceptance.reload.erased_at
    end

    test "model permits due payload erasure under a retired snapshotted erase policy" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = due_consent!(requirement:, version:)
      acceptance.retention_policy.update!(status: "retired")
      acceptance.assign_attributes(
        accepted_by_user_id: nil,
        evidence_digest: nil,
        request_uuid: nil,
        idempotency_key_digest: nil,
        erased_at: Time.current
      )

      assert_predicate acceptance, :valid?
    end

    test "allows due payload erasure when its policy permits it and no hold applies" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = due_consent!(requirement:, version:)
      erased_at = Time.current

      erase_payload!(acceptance, erased_at:)

      erased = acceptance.reload
      assert_equal erased_at.to_i, erased.erased_at.to_i
      assert_nil erased.accepted_by_user_id
      assert_nil erased.evidence_digest
      assert_nil erased.request_uuid
      assert_nil erased.idempotency_key_digest
      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationConsent.where(id: acceptance.id).update_all(erased_at: 1.minute.from_now)
      end
    end

    test "buyer coordinates and slot coordinates are mutually exclusive" do
      _document, version = create_consent_document(scope: "buyer")
      invalid = Ticketing::RegistrationConsentRequirement.new(
        registration: @registration,
        consent_document_version: version,
        required: true,
        acceptance_scope: "buyer",
        package_unit_number: 1,
        status: "pending",
        required_reason: "initial_submission",
        required_at: Time.current
      )

      assert_not invalid.valid?
      assert invalid.errors[:package_unit_number].present?
    end

    test "withdrawal model rejects buyer-scope consent" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

      withdrawal = Ticketing::RegistrationConsentWithdrawal.new(
        registration_consent: acceptance,
        registration: @registration,
        withdrawn_by_user: @actor,
        idempotency_key: "a" * 64,
        withdrawn_at: Time.current
      )

      assert_not withdrawal.valid?
      assert withdrawal.errors[:registration_consent].present?
    end

    test "withdrawal model rejects a non-current requirement" do
      _document, version = create_consent_document(scope: "admission_slot")
      requirement = build_consent_requirements.value.first
      assign_slot!(requirement, subject: @actor)
      acceptance = Ticketing::RegistrationConsent.new(
        registration_consent_requirement: requirement,
        registration: @registration,
        accepted_by_user: @actor
      )
      withdrawal = Ticketing::RegistrationConsentWithdrawal.new(
        registration_consent: acceptance,
        registration: @registration,
        withdrawn_by_user: @actor,
        idempotency_key: "b" * 64,
        withdrawn_at: Time.current
      )

      assert_not withdrawal.valid?
      assert withdrawal.errors[:registration_consent].present?
    end

    test "database rejects a buyer withdrawal even when service validations are bypassed" do
      _document, version = create_consent_document(scope: "buyer")
      requirement = build_consent_requirements(accept_required_buyer: false).value.first
      acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_withdrawal!(acceptance, "c" * 64)
      end
    end

    test "database rejects withdrawal for a non-current requirement" do
      _document, version = create_consent_document(scope: "admission_slot")
      requirement = build_consent_requirements.value.first
      assign_slot!(requirement, subject: @actor)
      acceptance = accept_consent(requirement:, content_sha256: version.content_sha256).value
      Ticketing::RegistrationConsentRequirement.where(id: requirement.id).update_all(
        status: "superseded", superseded_at: Time.current
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        insert_withdrawal!(acceptance, "d" * 64)
      end
    end

    private

    def insert_withdrawal!(acceptance, idempotency_key)
      now = Time.current
      Ticketing::RegistrationConsentWithdrawal.insert_all!([
        {
          id: SecureRandom.uuid,
          registration_consent_id: acceptance.id,
          registration_id: @registration.id,
          withdrawn_by_user_id: @actor.id,
          idempotency_key:,
          withdrawn_at: now,
          created_at: now,
          updated_at: now
        }
      ])
    end

    def due_consent!(requirement:, version:)
      accepted_at = 31.days.ago.change(nsec: 0)
      @retention_policy.update!(status: "retired")
      retention_policy = Core::DataRetentionPolicy.create!(
        category: "consent_evidence",
        version: Core::DataRetentionPolicy.where(category: "consent_evidence").maximum(:version) + 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: accepted_at - 1.minute,
        created_by: core_users(:super_admin)
      )
      insert_consent!(requirement:, version:, accepted_at:, retention_policy:)
      Ticketing::RegistrationConsent.find_by!(registration_consent_requirement_id: requirement.id)
    end

    def erase_payload!(acceptance, erased_at: Time.current)
      Ticketing::RegistrationConsent.where(id: acceptance.id).update_all(
        accepted_by_user_id: nil,
        evidence_digest: nil,
        request_uuid: nil,
        idempotency_key_digest: nil,
        erased_at:,
        updated_at: erased_at
      )
    end

    def insert_consent!(requirement:, version:, evidence_digest: nil, retention_policy: @retention_policy,
      retain_until: nil, accepted_at: Time.current.change(nsec: Time.current.nsec - (Time.current.nsec % 1000)))
      request_uuid = SecureRandom.uuid
      Ticketing::RegistrationConsent.insert_all!([
        {
          id: SecureRandom.uuid,
          registration_consent_requirement_id: requirement.id,
          registration_id: @registration.id,
          accepted_by_user_id: @actor.id,
          signer_role: "buyer",
          acceptance_method: "otp",
          content_sha256: version.content_sha256,
          evidence_digest: evidence_digest || Ticketing::RegistrationConsent.evidence_digest_for(
            registration_id: @registration.id,
            subject_user_id: @actor.id,
            accepted_by_user_id: @actor.id,
            version_id: version.id,
            content_sha256: version.content_sha256,
            signer_role: "buyer",
            acceptance_method: "otp",
            accepted_at:,
            request_uuid:
          ),
          idempotency_key_digest: SecureRandom.hex(32),
          request_uuid:,
          retention_policy_id: retention_policy.id,
          retain_until: retain_until || accepted_at + retention_policy.retention_days.days,
          accepted_at:,
          created_at: accepted_at,
          updated_at: accepted_at
        }
      ])
    end
  end
end
