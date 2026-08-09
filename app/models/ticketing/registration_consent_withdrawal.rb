# frozen_string_literal: true

module Ticketing
  # Append-only proof that the original signer withdrew an acceptance. The
  # command key is stored only as a SHA-256 digest for replay safety.
  class RegistrationConsentWithdrawal < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_consent_withdrawals"

    REASON_CODES = %w[attendee_request privacy_request legal_request changed_mind].freeze

    belongs_to :registration_consent,
               class_name: "Ticketing::RegistrationConsent"
    belongs_to :registration, class_name: "Ticketing::Registration"
    belongs_to :withdrawn_by_user, class_name: "Core::User"

    validates :idempotency_key, presence: true,
                                format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: true
      validates :reason_code, inclusion: { in: REASON_CODES }, allow_nil: true
      validates :withdrawn_at, presence: true
      validate :same_registration
      validate :original_signer
      validate :accepted_personal_requirement
    before_update :prevent_update
    before_destroy :prevent_destroy

    def self.ransackable_attributes(_auth_object = nil)
      %w[id registration_consent_id registration_id withdrawn_by_user_id withdrawn_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration_consent registration withdrawn_by_user]
    end

    private

    def same_registration
      return if registration_consent.blank? || registration_id == registration_consent.registration_id

      errors.add(:registration_id, :invalid)
    end

      def original_signer
        return if registration_consent.blank? || withdrawn_by_user_id == registration_consent.accepted_by_user_id

        errors.add(:withdrawn_by_user_id, :invalid)
      end

      def accepted_personal_requirement
        return if persisted?

        requirement = registration_consent&.registration_consent_requirement
        return if requirement&.accepted? && requirement.acceptance_scope == "admission_slot"

        errors.add(:registration_consent, :invalid)
      end

    def prevent_update
      raise ActiveRecord::ReadOnlyRecord, "Registration consent withdrawals are immutable"
    end

    def prevent_destroy
      raise ActiveRecord::ReadOnlyRecord, "Registration consent withdrawals are immutable"
    end
  end
end
