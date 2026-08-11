module Core
  # Short-lived, single-use proof that binds a fresh factor to one access session.
  class ReauthenticationProof < Core::ApplicationRecord
    self.table_name = "core_reauthentication_proofs"

    PURPOSES = %w[attendee_export_request attendee_export_download].freeze
    FACTOR_TYPES = %w[password].freeze
    LIFETIME = 5.minutes
    DIGEST_FORMAT = /\A[0-9a-f]{64}\z/

    belongs_to :user, class_name: "Core::User", inverse_of: :reauthentication_proofs

    validates :user, presence: true
    validates :purpose, presence: true,
      inclusion: { in: PURPOSES, message: ->(*) { I18n.t("reauthentication.model_errors.invalid_purpose") } }
    validates :factor_type, presence: true,
      inclusion: { in: FACTOR_TYPES, message: ->(*) { I18n.t("reauthentication.model_errors.invalid_factor") } }
    validates :session_jti_digest, presence: true, format: {
      with: DIGEST_FORMAT,
      message: ->(*) { I18n.t("reauthentication.model_errors.invalid_digest") }
    }
    validates :token_digest, presence: true, uniqueness: {
      message: ->(*) { I18n.t("reauthentication.model_errors.token_digest_taken") }
    }, format: {
      with: DIGEST_FORMAT,
      message: ->(*) { I18n.t("reauthentication.model_errors.invalid_digest") }
    }
    validates :issued_at, :expires_at, presence: true
    validate :exact_lifetime
    validate :consumed_after_issue

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id user_id session_jti_digest purpose factor_type token_digest
        issued_at expires_at consumed_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user]
    end

    private

    def exact_lifetime
      return if issued_at.blank? || expires_at.blank?
      return if expires_at == issued_at + LIFETIME

      errors.add(:expires_at, I18n.t("reauthentication.model_errors.invalid_lifetime"))
    end

    def consumed_after_issue
      return if consumed_at.blank? || issued_at.blank?
      return if consumed_at >= issued_at

      errors.add(:consumed_at, I18n.t("reauthentication.model_errors.invalid_consumed_at"))
    end
  end
end
