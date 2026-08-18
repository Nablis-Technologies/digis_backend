# frozen_string_literal: true

module Commercial
  module Defaults
    # Resolves the one platform-default version an organization may use at a
    # quote time. Missing notice or acceptance evidence fails closed; it never
    # silently falls back to a newly effective worsening definition.
    class EligibleVersion < Core::BaseService
      def initialize(organization:, at: Time.current)
        @organization = organization
        @at = at.to_time
      end

      def call
        versions = candidate_versions
        return failure(error("default_version_required")) if versions.empty?

        version = versions.first
        return failure(error("none_worsening_forbidden")) if worsening_none?(version)
        return failure(error("legal_version_required")) if protected_policy_without_legal?(version)
        return failure(error("legal_version_not_published")) if protected_policy_with_unpublished_legal?(version)

        protected_policy_result(version)
      end

      private

      attr_reader :organization, :at

      def candidate_versions
        Commercial::FeeScheduleVersion
          .active_at(at)
          .joins(:fee_schedule)
          .where(commercial_fee_schedules: { schedule_type: "platform_default" })
          .includes(:fee_schedule, :legal_document_version, :supersedes_version)
          .order(commercial_fee_schedule_versions: { effective_from: :desc, id: :desc })
          .to_a
      end

      def protected_policy_result(version)
        return success(version) if version.acceptance_policy == "none"

        case version.acceptance_policy
        when "notice_only"
          return success(version) if notice_available?(version)

          failure(error("notice_required"))
        when "explicit"
          return success(version) if accepted_exactly?(version)

          previous = grandfathered_previous_version(version)
          return success(previous) if previous

          failure(error("acceptance_required"))
        else
          failure(error("no_eligible_version"))
        end
      end

      def notice_available?(version)
        TermNotice.delivered.where(
          organization_id: organization.id, fee_schedule_version_id: version.id,
          delivery_method: "in_app"
        ).where("available_at < ?", version.effective_from).exists?
      end

      def accepted_exactly?(version)
        Legal::LegalAcceptance.exists?(
          subject_type: "organization", subject_id: organization.id,
          legal_document_version_id: version.legal_document_version_id
        )
      end

      def grandfathered_previous_version(version)
        return if version.grandfather_until.blank? || at >= version.grandfather_until

        previous = version.supersedes_version
        return if previous.blank?
        return unless previous.legal_document_version_id.present?

        return unless Legal::LegalAcceptance.exists?(
          subject_type: "organization", subject_id: organization.id,
          legal_document_version_id: previous.legal_document_version_id
        )

        previous
      end

      def worsening_none?(version)
        version.acceptance_policy == "none" && latest_classification(version) == "worsening"
      end

      def protected_policy_without_legal?(version)
        version.acceptance_policy.in?(%w[notice_only explicit]) && version.legal_document_version.blank?
      end

      def protected_policy_with_unpublished_legal?(version)
        version.acceptance_policy.in?(%w[notice_only explicit]) && version.legal_document_version.present? && !version.legal_document_version.published?
      end

      def latest_classification(version)
        Commercial::Simulation.where(fee_schedule_version_id: version.id, assignment_id: nil, passed: true)
          .where(definition_digest: version.definition_digest)
          .order(run_at: :desc).pick(Arel.sql("normalized_outputs ->> 'classification'"))
      end

      def error(code)
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.#{code}"), code:, status: :unprocessable_entity
        )
      end
    end
  end
end
