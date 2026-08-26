# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Registers encrypted beneficiary details and performs provider-first
    # verification without treating local format checks as ownership proof.
    class Register < Core::BaseService
      include CommandSupport

      def initialize(organization:, type:, provider:, bank_code:, account_number:,
        account_name: nil, account_label: nil, adapter:, idempotency_key:,
        actor: nil, verification_source: nil, at: Time.current)
        @organization = organization
        @type = type.to_s.strip.downcase
        @provider = provider.to_s.strip.downcase
        @bank_code = bank_code
        @account_number = account_number.to_s.strip
        @account_name = account_name.to_s.strip.presence
        @account_label = account_label.to_s.strip.presence
        @adapter = adapter
        @idempotency_key = idempotency_key
        @actor = actor
        @verification_source = verification_source.to_s.strip.downcase.presence
        @at = at.to_time.utc
      end

      def call
        key = normalize_command_key(idempotency_key)
        audit_key = command_audit_key("registered", key)
        request_digest = command_request_digest(
          operation: "register", account_id: nil, actor:,
          identity: {
            organization_id: organization&.id, type:, provider:, bank_code: bank_code.to_i,
            account_number:, account_name:, account_label:, verification_source:
          }
        )
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        return failure(input_error) unless valid_input_shape?
        return failure(bank_error) unless bank_code_supported?
        return failure(input_error) if fixture_source? && !fixture_allowed?

        verification = verification_result(key)
        return failure(verification_error(verification)) if verification.failure?

        account = persist_account!(key:, audit_key:, request_digest:, verification:)
        return failure(account) if account.is_a?(Core::BusinessError)

        success(account)
      rescue ArgumentError
        failure(input_error)
      rescue Core::Audit::ReplayConflict
        failure(finance_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
      rescue ActiveRecord::RecordNotUnique
        failure(finance_error(:payout_account_conflict, code: "payout_account_conflict", status: :conflict))
      end

      private

      attr_reader :organization, :type, :provider, :bank_code, :account_number,
        :account_name, :account_label, :adapter, :idempotency_key, :actor,
        :verification_source, :at

      def valid_input_shape?
        organization.present? &&
          PayoutAccount::TYPES.include?(type) &&
          PayoutAccount::PROVIDERS.include?(provider) &&
          bank_code.to_i.positive? &&
          account_number.present? &&
          (verification_source.blank? || verification_source == "test_fixture")
      end

      def fixture_source?
        verification_source == "test_fixture"
      end

      def fixture_allowed?
        Rails.env.test? || Rails.env.development? || ENV["RENDER_PREVIEW"] == "true"
      end

      def bank_code_supported?
        banks = adapter.available_banks
        # A provider outage is unknown, not proof that every bank is valid.
        return true if banks.nil?

        banks.include?(bank_code.to_i)
      end

      def verification_result(key)
        return Finance::PayoutProviders::Result.success(raw_status: "test_fixture") if fixture_source?

        Finance::PayoutProviders::Result.from_provider_response(
          adapter.verify_payout_account(
            account_number:, account_name:, bank_code: bank_code.to_i,
            idempotency_key: key.to_s
          )
        )
      end

      def persist_account!(key:, audit_key:, request_digest:, verification:)
        digest = PayoutAccountDigest.call(organization:, account_number:)
        Finance::ApplicationRecord.transaction do
          Core::Database::AdvisoryLock.acquire!("finance-payout-account", organization.id, provider, digest)
          existing = PayoutAccount.lock.find_by(organization:, provider:, account_number_digest: digest)
          return existing if existing && command_replay_matches?(audit_key:, request_digest:)
          return conflict_error if existing

          account = PayoutAccount.new(
            organization:, type:, provider:, bank_code: bank_code.to_i,
            account_number:, account_name:, account_label:,
            account_number_digest: digest,
            **verification_attributes(verification)
          )
          account.save!
          account.record_audit!(
            "finance.payout_account.registered",
            audit_key:,
            audited_changes: { status: [ nil, account.status ] },
            metadata: {
              account_id: account.id, provider:, verification_source: account.verification_source,
              idempotency_key: key.to_s, request_digest:
            },
            actor:
          )
          account
        end
      rescue ActiveRecord::RecordInvalid => error
        Core::BusinessError.new(
          I18n.t("finance.errors.payout_account_invalid"),
          code: "payout_account_invalid", status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      def verification_attributes(result)
        return { status: "pending_verification" } if result.unknown? || result.timeout?

        { status: "verified", verification_source: verification_source || "provider", verified_at: at }
      end

      def verification_error(result)
        finance_error(
          :payout_account_verification_failed,
          code: result.failure_code.presence || "payout_account_verification_failed"
        )
      end

      def input_error
        finance_error(:payout_account_input_invalid, code: "payout_account_input_invalid")
      end

      def bank_error
        finance_error(:payout_account_bank_unsupported, code: "payout_account_bank_unsupported")
      end

      def conflict_error
        finance_error(:payout_account_conflict, code: "payout_account_conflict", status: :conflict)
      end
    end
  end
end
