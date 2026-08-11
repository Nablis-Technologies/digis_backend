# frozen_string_literal: true

require "digest"

module Ticketing
  # Append-only acceptance evidence for one exact consent requirement. The row
  # stores hashes and policy evidence, never the document body or signer data.
  class RegistrationConsent < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_consents"

    SIGNER_ROLES = %w[buyer attendee].freeze
    ACCEPTANCE_METHODS = %w[checkbox otp].freeze
    UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    belongs_to :registration_consent_requirement,
               class_name: "Ticketing::RegistrationConsentRequirement"
    belongs_to :registration, class_name: "Ticketing::Registration"
    belongs_to :accepted_by_user, class_name: "Core::User", optional: true
    belongs_to :retention_policy, class_name: "Core::DataRetentionPolicy"

    has_one :withdrawal,
            class_name: "Ticketing::RegistrationConsentWithdrawal",
            dependent: :restrict_with_exception

    validates :signer_role, presence: true, inclusion: { in: SIGNER_ROLES }
    validates :acceptance_method, presence: true, inclusion: { in: ACCEPTANCE_METHODS }
    validates :content_sha256, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :evidence_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }, unless: :erased?
    validates :idempotency_key_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ },
                                       uniqueness: true, unless: :erased?
    validates :request_uuid, presence: true, format: { with: UUID_FORMAT }, uniqueness: true, unless: :erased?
    validates :accepted_at, presence: true
    validate :same_registration
    validate :requirement_is_pending
    validate :exact_version_digest
    validate :signer_matches_requirement
    validate :retention_snapshot
    validate :evidence_digest_matches_stored_fields, on: :create, unless: :erased?
    validate :erasure_payload, if: :erased?
    validate :erasure_permitted, if: :erasure_transition?
    before_update :prevent_update_unless_erasure
    before_destroy :prevent_destroy

    def self.evidence_digest_for(registration_id:, subject_user_id:, accepted_by_user_id:, version_id:,
      content_sha256:, signer_role:, acceptance_method:, accepted_at:, request_uuid:)
      payload = {
        registration_id:,
        subject_user_id:,
        accepted_by_user_id:,
        version_id:,
        content_sha256:,
        signer_role:,
        acceptance_method:,
        accepted_at: accepted_at.utc.iso8601(6),
        request_uuid:
      }
      Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(payload))
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id registration_consent_requirement_id registration_id accepted_by_user_id signer_role
        acceptance_method retention_policy_id retain_until accepted_at erased_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration_consent_requirement registration accepted_by_user retention_policy withdrawal]
    end

    private

    def same_registration
      return if registration.blank? || registration_consent_requirement.blank?
      return if registration_consent_requirement.registration_id == registration_id

      errors.add(:registration_id, :invalid)
    end

    def requirement_is_pending
      return if registration_consent_requirement.blank? || persisted?
      return if registration_consent_requirement.pending?

      errors.add(:registration_consent_requirement, :invalid)
    end

    def exact_version_digest
      version = registration_consent_requirement&.consent_document_version
      return if version.blank? || content_sha256 == version.content_sha256

      errors.add(:content_sha256, :invalid)
    end

    def evidence_digest_matches_stored_fields
      return if registration_consent_requirement.blank? || accepted_by_user_id.blank? || request_uuid.blank?
      return if evidence_digest == self.class.evidence_digest_for(
        registration_id:,
        subject_user_id: registration_consent_requirement.subject_user_id,
        accepted_by_user_id:,
        version_id: registration_consent_requirement.consent_document_version_id,
        content_sha256:,
        signer_role:,
        acceptance_method:,
        accepted_at:,
        request_uuid:
      )

      errors.add(:evidence_digest, :invalid)
    end

    def signer_matches_requirement
      requirement = registration_consent_requirement
      return if requirement.blank? || accepted_by_user.blank?

      if requirement.acceptance_scope == "buyer"
        valid = signer_role == "buyer" && accepted_by_user_id == registration.user_id
      else
        valid = signer_role == "attendee" && accepted_by_user_id == requirement.subject_user_id
      end
      errors.add(:accepted_by_user_id, :invalid) unless valid
    end

    def retention_snapshot
      return if retention_policy.blank? || accepted_at.blank?
      policy_statuses = persisted? ? %w[active retired] : [ "active" ]
      unless policy_statuses.include?(retention_policy.status) && retention_policy.category == "consent_evidence" &&
             retention_policy.effective_at.present? && retention_policy.effective_at <= accepted_at
        errors.add(:retention_policy, :invalid)
        return
      end

      expected = retention_policy.retention_days && accepted_at + retention_policy.retention_days.days
      return if retain_until == expected

      errors.add(:retain_until, :invalid)
    end

    def erasure_payload
      return if accepted_by_user_id.blank? && evidence_digest.blank? && request_uuid.blank? && idempotency_key_digest.blank?

      errors.add(:base, :invalid)
    end

    def erasure_permitted
      if retention_policy.action != "erase_payload" || retain_until.blank? || retain_until > Time.current
        errors.add(:erased_at, :invalid)
      elsif active_evidence_hold?
        errors.add(:erased_at, :invalid)
      end
    end

    def active_evidence_hold?
      Core::DataRetentionHold.active
        .where(category: [ nil, "consent_evidence" ])
        .where(
          "registration_id = :registration_id OR " \
          "event_id = (SELECT event_id FROM ticketing_registrations WHERE id = :registration_id) OR " \
          "user_id = :accepted_by_user_id",
          registration_id:,
          accepted_by_user_id: accepted_by_user_id_in_database
        )
        .exists?
    end

    def erased?
      erased_at.present?
    end

    def prevent_update_unless_erasure
      return if erasure_transition?

      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_registration_consent")
    end

    def erasure_transition?
      erased_at_in_database.blank? && erased_at.present? &&
        accepted_by_user_id.blank? && evidence_digest.blank? && request_uuid.blank? &&
        idempotency_key_digest.blank? &&
        (changes.keys - %w[accepted_by_user_id evidence_digest request_uuid idempotency_key_digest erased_at updated_at]).empty?
    end

    def prevent_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_registration_consent")
    end
  end
end
