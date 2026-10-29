# frozen_string_literal: true

module Marketplace
  # Registers one encrypted seller destination and keeps provider verification
  # separate from bank-code validation. Chapa's unsupported preflight verifier
  # leaves a safe pending account for the audited manual workflow.
  class VerifyPayoutAccount < Core::BaseService
    include SellerPayoutAccounts::CommandSupport

    def initialize(user:, type:, provider:, bank_slug:, account_number:, account_label: nil,
      holder_name: nil, adapter:, idempotency_key:, verification_source: nil, at: Time.current)
      @user = user
      @user_id = user&.id
      @type = type.to_s.strip.downcase
      @provider = provider.to_s.strip.downcase
      @bank_slug = bank_slug.to_s.strip.downcase
      @account_number = account_number.to_s.strip
      @account_label = account_label.to_s.strip.presence
      @holder_name = holder_name.to_s.strip.presence
      @adapter = adapter
      @idempotency_key = idempotency_key
      @verification_source = verification_source.to_s.strip.downcase.presence
      @at = at.to_time.utc
    end

    def call
      key = Core::IdempotencyKey.new(idempotency_key)
      audit_key = command_audit_key("registered", key)
      request_digest = registration_request_digest if user_id.present?
      if request_digest
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay
      end
      return failure(input_error) unless valid_input?
      destinations = PayoutProviders::DestinationCatalog.call(
        adapter:, provider:, country: "ET", currency: "ETB"
      )
      return failure(destinations.error) if destinations.failure?
      return failure(bank_error) unless destination_supported?(destinations.value)

      verification = verification_result(key)
      return failure(verification_failed_error(verification)) if verification.failure? || verification.cancelled?

      account = persist_account!(key:, request_digest:, audit_key:, verification:)
      return failure(account) if account.is_a?(Core::BusinessError)

      success(account)
    rescue ArgumentError
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_input_invalid"),
        code: "payout_account_input_invalid", status: :unprocessable_entity
      ))
    rescue Core::Audit::Record::ReplayConflict
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.idempotency_conflict"),
        code: "idempotency_conflict", status: :conflict
      ))
    rescue ActiveRecord::RecordNotUnique
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_conflict"),
        code: "payout_account_conflict", status: :conflict
      ))
    end

    private

    attr_reader :user, :user_id, :type, :provider, :bank_slug, :account_number, :account_label,
      :holder_name, :adapter, :idempotency_key, :verification_source, :at

    def valid_input?
      SellerPayoutAccount::TYPES.include?(type) && SellerPayoutAccount::PROVIDERS.include?(provider) &&
        bank_slug.match?(/\A[a-z0-9][a-z0-9_-]*\z/) && account_number.present? && holder_name.present? &&
        user.present? &&
        (verification_source.blank? || verification_source == "test_fixture") &&
        (verification_source != "test_fixture" || fixture_allowed?)
    end

    def input_error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_input_invalid"),
        code: "payout_account_input_invalid", status: :unprocessable_entity
      )
    end

    def bank_error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_bank_unsupported"),
        code: "payout_account_bank_unsupported", status: :unprocessable_entity
      )
    end

    def destination_supported?(destinations)
      destinations.any? { |destination| destination[:type] == type && destination[:bank_slug] == bank_slug }
    end

    def fixture_allowed?
      Rails.env.test? || Rails.env.development? || ENV["RENDER_PREVIEW"] == "true"
    end

    def registration_request_digest
      command_request_digest(
        operation: "register", account_id: nil, actor: user,
        identity: {
          type:, provider:, bank_slug:,
          account_number_digest: account_digest, account_label:, holder_name:
        }
      )
    end

    def account_digest
      @account_digest ||= Core::PayoutAccountDigest.call(namespace: user.id, account_number:)
    end

    def verification_result(key)
      return Marketplace::PayoutProviders::Result.success(raw_status: "test_fixture") if verification_source == "test_fixture"

      normalize_provider_result(adapter.verify_payout_account(
        account_number:, account_name: holder_name, bank_slug:, type:, provider:,
        idempotency_key: key.to_s
      ))
    end

    def persist_account!(key:, request_digest:, audit_key:, verification:)
      Marketplace::SellerPayoutAccount.transaction do
        digest = account_digest
        Core::Database::AdvisoryLock.acquire!("marketplace-payout-account", user_id, provider, digest)
        existing = SellerPayoutAccount.lock.find_by(user_id:, provider:, account_number_digest: digest)
        if existing
          next existing if command_replay_matches?(audit_key:, request_digest:)

          next conflict_error
        end

        account = SellerPayoutAccount.new(
          user:, type:, provider:, bank_slug:, account_number:,
          account_number_digest: digest, account_label:, holder_name:,
          **verification_attributes(verification), is_default: false
        )
        account.save!
        account.record_audit!(
          "marketplace.seller_payout_account.registered",
          audited_changes: { status: [ nil, account.status ] },
          metadata: {
            account_id: account.id, provider:, verification_source: account.verification_source,
            idempotency_key: key.to_s, request_digest:
          },
          actor: user,
          audit_key:
        )
        record_verification_audit!(account, key:, request_digest:) if account.verified?
        account
      end
    rescue ActiveRecord::RecordInvalid => error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_invalid"),
        code: "payout_account_invalid", status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      )
    end

    def verification_attributes(result)
      return {
        status: "verified", verification_source: verification_source || "provider",
        verified_by: nil, verified_at: at
      } if result.success?

      { status: "pending_verification", verification_source: nil, verified_by: nil, verified_at: nil }
    end

    def record_verification_audit!(account, key:, request_digest:)
      account.record_audit!(
        "marketplace.seller_payout_account.verified",
        audited_changes: {
          status: [ nil, "verified" ], verification_source: [ nil, account.verification_source ],
          verified_at: account.verified_at.iso8601
        },
        metadata: { account_id: account.id, provider: account.provider, idempotency_key: key.to_s, request_digest: },
        actor: user,
        audit_key: command_audit_key("verified", key)
      )
    end

    def verification_failed_error(result)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_verification_failed"),
        code: result.failure_code.presence || result.status.to_s.presence || "payout_account_verification_failed",
        status: :unprocessable_entity
      )
    end

    def normalize_provider_result(response)
      Marketplace::PayoutProviders::Result.from_provider_response(response)
    end

    def conflict_error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_conflict"),
        code: "payout_account_conflict", status: :conflict
      )
    end
  end
end
