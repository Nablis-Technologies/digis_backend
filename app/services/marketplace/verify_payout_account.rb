# frozen_string_literal: true

module Marketplace
  # Tokenizes and verifies one seller destination. Provider credentials live
  # only in the adapter call; the account row stores the provider token and
  # encrypted display values, and the audit record contains no sensitive data.
  class VerifyPayoutAccount < Core::BaseService
    def initialize(user:, type:, provider:, account_details:, account_label: nil, holder_name: nil,
      adapter:, idempotency_key:, at: Time.current)
      @user = user
      @user_id = user.id
      @type = type.to_s.strip.downcase
      @provider = provider.to_s.strip.downcase
      @account_details = account_details
      @account_label = account_label.to_s.strip.presence
      @holder_name = holder_name.to_s.strip.presence
      @adapter = adapter
      @idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      key = Core::IdempotencyKey.new(idempotency_key)
      return failure(input_error) unless valid_input?

      audit_key = "marketplace-seller-payout-account-verified-#{key.digest}"
      replay = Core::AuditLog.find_by(audit_key:)
      return replay_account(replay) if replay

      tokenized = normalize_tokenization(adapter.tokenize_payout_account(
        user_id: user_id,
        type:,
        provider:,
        account_label:,
        holder_name:,
        account_details:,
        idempotency_key: key.to_s
      ))
      return failure(tokenized) if tokenized.is_a?(Core::BusinessError)

      account = persist_pending_account!(tokenized.fetch(:account_token))
      return failure(account) if account.is_a?(Core::BusinessError)

      verification = normalize_provider_result(adapter.verify_payout_account(
        account_token: account.account_token,
        type: account.type,
        provider: account.provider,
        idempotency_key: key.to_s
      ))
      apply_verification!(account, verification, key:, audit_key:)
    rescue ArgumentError
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_input_invalid"),
        code: "payout_account_input_invalid", status: :unprocessable_entity
      ))
    rescue NotImplementedError
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_provider_unavailable"),
        code: "payout_account_provider_unavailable", status: :unprocessable_entity
      ))
    rescue ActiveRecord::RecordNotUnique
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_conflict"),
        code: "payout_account_conflict", status: :conflict
      ))
    end

    private

    attr_reader :user, :user_id, :type, :provider, :account_details, :account_label, :holder_name,
      :adapter, :idempotency_key, :at

    def valid_input?
      account_details.is_a?(Hash) && SellerPayoutAccount::TYPES.include?(type) &&
        SellerPayoutAccount::PROVIDERS.include?(provider) && holder_name.present?
    end

    def input_error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_input_invalid"),
        code: "payout_account_input_invalid", status: :unprocessable_entity
      )
    end

    def normalize_tokenization(response)
      attributes = response.to_h.deep_symbolize_keys
      token = attributes[:account_token] || attributes[:token]
      return token_error if token.to_s.strip.blank?

      { account_token: token.to_s.strip }
    rescue NoMethodError, TypeError
      token_error
    end

    def token_error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_token_invalid"),
        code: "payout_account_token_invalid", status: :unprocessable_entity
      )
    end

    def persist_pending_account!(account_token)
      Marketplace::SellerPayoutAccount.transaction do
        Core::Database::AdvisoryLock.acquire!("marketplace-payout-account", user_id, provider, account_token)
        existing = SellerPayoutAccount.lock.find_by(provider:, account_token:)
        if existing && existing.user_id != user_id
          next Core::BusinessError.new(
            I18n.t("marketplace.resale.errors.payout_account_conflict"),
            code: "payout_account_conflict", status: :conflict
          )
        end

        account = existing || SellerPayoutAccount.new(user_id:, type:, provider:, account_token:)
        account.assign_attributes(
          type:,
          account_label_ciphertext: account_label,
          holder_name_ciphertext: holder_name,
          status: "pending_verification",
          verified_at: nil
        )
        account.save!
        account
      end
    rescue ActiveRecord::RecordInvalid => error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_invalid"),
        code: "payout_account_invalid", status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      )
    end

    def apply_verification!(account, result, key:, audit_key:)
      return failure(verification_pending_error) if result.unknown? || result.timeout?
      return failure(verification_failed_error(result)) unless result.success?

      verified = Marketplace::SellerPayoutAccount.transaction do
        locked = SellerPayoutAccount.lock.find(account.id)
        locked.update!(status: "verified", verified_at: at)
        locked.record_audit!(
          "marketplace.seller_payout_account.verified",
          audited_changes: { status: [ "pending_verification", "verified" ], verified_at: at.iso8601 },
          metadata: { account_id: locked.id, provider: locked.provider, idempotency_key: key.to_s },
          actor: user,
          audit_key:
        )
        locked
      end
      success(verified)
    rescue ActiveRecord::RecordInvalid => error
      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_invalid"),
        code: "payout_account_invalid", status: :conflict, errors: error.record.errors.to_hash
      ))
    end

    def replay_account(audit)
      account = SellerPayoutAccount.find_by(id: audit.metadata["account_id"] || audit.metadata[:account_id])
      return success(account) if account

      failure(Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_replay_missing"),
        code: "payout_account_replay_missing", status: :conflict
      ))
    end

    def verification_pending_error
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_verification_pending"),
        code: "payout_account_verification_pending", status: :unprocessable_entity
      )
    end

    def verification_failed_error(result)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.payout_account_verification_failed"),
        code: result.failure_code.presence || "payout_account_verification_failed",
        status: :unprocessable_entity
      )
    end

    def normalize_provider_result(response)
      Marketplace::PayoutProviders::Result.from_provider_response(response)
    end
  end
end
