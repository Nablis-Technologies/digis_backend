# frozen_string_literal: true

require "digest"
require "json"

module Commercial
  # Durable in-app delivery evidence for one exact platform-default version.
  # This record is the organizer terms inbox boundary; Messaging may add
  # secondary notifications later, but cannot replace this evidence.
  class TermNotice < Commercial::ApplicationRecord
    self.table_name = "commercial_term_notices"

    DELIVERY_METHODS = %w[in_app].freeze
    STATUSES = %w[pending delivered failed].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :fee_schedule_version,
               class_name: "Commercial::FeeScheduleVersion",
               inverse_of: :term_notices
    belongs_to :legal_document_version, class_name: "Legal::LegalDocumentVersion"

    validates :delivery_method, presence: true, inclusion: { in: DELIVERY_METHODS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :evidence_digest, :idempotency_key_digest,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :available_at, presence: true
    validates :delivered_at, presence: true, if: -> { status == "delivered" }
    validates :failed_at, presence: true, if: -> { status == "failed" }
    validate :platform_default_version
    validate :legal_version_matches_fee_version
    validate :evidence_digest_matches_delivery
    validate :delivery_state_metadata

    scope :delivered, -> { where(status: "delivered") }
    scope :for_organization, ->(organization_id) { where(organization_id:) }
    scope :available_before, ->(time) { delivered.where("available_at < ?", time) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id organization_id fee_schedule_version_id legal_document_version_id delivery_method status evidence_digest available_at delivered_at failed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[organization fee_schedule_version legal_document_version]
    end

    def visible_to?(user)
      user.present? && (user.super_admin? || user.member_of?(organization))
    end

    def self.evidence_digest_for(organization_id:, fee_schedule_version_id:, legal_document_version_id:,
                                 delivery_method:, delivered_at:)
      Digest::SHA256.hexdigest(
        JSON.generate(
          organization_id:, fee_schedule_version_id:, legal_document_version_id:,
          delivery_method:, delivered_at:
        )
      )
    end

    private

    def platform_default_version
      return if fee_schedule_version.blank?
      return if fee_schedule_version.fee_schedule.schedule_type == "platform_default"

      errors.add(:fee_schedule_version, I18n.t("commercial.governance.errors.term_notice_default_required"))
    end

    def legal_version_matches_fee_version
      expected_id = fee_schedule_version&.legal_document_version_id
      return if expected_id.present? && expected_id == legal_document_version_id

      errors.add(:legal_document_version, I18n.t("commercial.governance.errors.term_notice_version_mismatch"))
    end

    def evidence_digest_matches_delivery
      return unless status == "delivered" && delivered_at.present?

      expected = self.class.evidence_digest_for(
        organization_id:, fee_schedule_version_id:, legal_document_version_id:,
        delivery_method:, delivered_at:
      )
      return if evidence_digest == expected

      errors.add(:evidence_digest, I18n.t("commercial.governance.errors.term_notice_evidence_mismatch"))
    end

    def delivery_state_metadata
      if status == "delivered" && failed_at.present?
        errors.add(:failed_at, I18n.t("commercial.governance.errors.delivered_notice_failed_at"))
      elsif status == "failed" && delivered_at.present?
        errors.add(:delivered_at, I18n.t("commercial.governance.errors.failed_notice_delivered_at"))
      elsif status == "pending" && (delivered_at.present? || failed_at.present?)
        errors.add(:status, I18n.t("commercial.governance.errors.pending_notice_metadata"))
      end
    end
  end
end
