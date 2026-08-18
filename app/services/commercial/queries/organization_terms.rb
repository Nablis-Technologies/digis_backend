# frozen_string_literal: true

module Commercial
  module Queries
    # Builds the organizer terms page from the same authoritative assignment
    # and platform-default records used by quote resolution. It returns a
    # read-only aggregate so organizers cannot mutate commercial definitions.
    class OrganizationTerms < Core::BaseService
      def initialize(organization:, at: Time.current)
        @organization = organization
        @at = at.to_time
      end

      def call
        assignments = organization_assignments
        default_version = eligible_default
        success(
          Commercial::OrganizationTerms.new(
            organization:,
            current_version: current_version(assignments, default_version),
            scheduled_version: scheduled_version(assignments),
            acceptance_history: acceptance_history,
            event_exceptions: event_exceptions(assignments)
          )
        )
      end

      private

      attr_reader :organization, :at

      def organization_assignments
        Commercial::Assignment
          .where(organization_id: organization.id)
          .where(status: %w[scheduled active])
          .includes(fee_schedule_version: { fee_components: %i[fee_amounts fee_tiers] })
          .to_a
      end

      def eligible_default
        result = Commercial::Defaults::EligibleVersion.call(organization:, at:)
        return unless result.success?

        Commercial::FeeScheduleVersion
          .includes(fee_components: %i[fee_amounts fee_tiers])
          .find(result.value.id)
      end

      def current_version(assignments, default_version)
        assignment = assignments.select { |item| item.event_id.blank? }
          .select { |item| item.effective_from <= at && (item.effective_until.blank? || item.effective_until > at) }
          .max_by(&:effective_from)
        assignment&.fee_schedule_version || default_version
      end

      def scheduled_version(assignments)
        assignment = assignments.select { |item| item.event_id.blank? && item.status == "scheduled" }
          .select { |item| item.effective_from > at }
          .min_by(&:effective_from)
        return assignment.fee_schedule_version if assignment

        Commercial::FeeScheduleVersion
          .where(status: "scheduled")
          .where("effective_from > ?", at)
          .joins(:fee_schedule)
          .where(commercial_fee_schedules: { schedule_type: "platform_default" })
          .includes(fee_components: %i[fee_amounts fee_tiers])
          .order(:effective_from, :id)
          .first
      end

      def acceptance_history
        Legal::LegalAcceptance
          .where(subject_type: "organization", subject_id: organization.id)
          .order(accepted_at: :desc)
          .pluck(:legal_document_version_id, :acceptance_method, :accepted_at)
          .map do |legal_version_id, method, accepted_at|
            { legal_document_version_id: legal_version_id, acceptance_method: method, accepted_at: }
          end
      end

      def event_exceptions(assignments)
        assignments.filter_map do |assignment|
          next if assignment.event_id.blank?

          {
            event_id: assignment.event_id,
            assignment_id: assignment.id,
            status: assignment.status,
            effective_from: assignment.effective_from,
            effective_until: assignment.effective_until
          }
        end
      end
    end
  end
end
