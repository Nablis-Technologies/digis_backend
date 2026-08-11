# frozen_string_literal: true

module Commercial
  module Resolution
    # Loads every candidate needed for one quote in bounded eager-loaded
    # relations. Candidate precedence is assigned here so selection never
    # performs additional database work or invents priority from persisted data.
    class CandidateQuery < Core::BaseService
      Candidate = Data.define(:component, :version, :assignment, :source, :precedence) do
        def component_type = component.component_type
      end

      SOURCE_PRECEDENCE = {
        event_assignment: 4,
        organization_assignment: 3,
        program: 2,
        platform_default: 1
      }.freeze

      def initialize(context:)
        @context = context
      end

      def call
        success(load_candidates)
      end

      private

      attr_reader :context

      def load_candidates
        # Keep candidates from every layer in one set. Selection is per
        # component, so an event override must not suppress inherited siblings.
        assignment_candidates + platform_default_candidates
      end

      def assignment_candidates
        assignments.flat_map do |assignment|
          source = assignment_source(assignment)
          next [] unless source
          next [] unless authoritative_at?(assignment.fee_schedule_version)
          next [] if source == :program && !program_active_at?(assignment.program)

          build_candidates(assignment.fee_schedule_version, assignment, source)
        end
      end

      def platform_default_candidates
        platform_default_versions.flat_map do |version|
          build_candidates(version, nil, :platform_default)
        end
      end

      def assignments
        return Commercial::Assignment.none if context.organization_id.blank?

        scope = Commercial::Assignment
          .active_at(context.quoted_at)
          .where(organization_id: context.organization_id)
          .includes(
            :program,
            fee_schedule_version: [
              :fee_schedule,
              { fee_components: %i[fee_amounts fee_tiers] }
            ]
          )
        context.event_id.present? ? scope.where(event_id: [ nil, context.event_id ]) : scope.where(event_id: nil)
      end

      def platform_default_versions
        Commercial::FeeScheduleVersion
          .active_at(context.quoted_at)
          .joins(:fee_schedule)
          .where(commercial_fee_schedules: { schedule_type: "platform_default" })
          .includes(:fee_schedule, fee_components: %i[fee_amounts fee_tiers])
          .to_a
      end

      def assignment_source(assignment)
        return :event_assignment if assignment.event_id.present?
        return :program if assignment.program_assignment?

        :organization_assignment
      end

      def build_candidates(version, assignment, source)
        version.fee_components.map do |component|
          Candidate.new(
            component:, version:, assignment:, source:, precedence: SOURCE_PRECEDENCE.fetch(source)
          )
        end
      end

      def authoritative_at?(version)
        return false unless version.authoritative?
        return false if version.effective_from.blank? || version.effective_from > context.quoted_at

        version.effective_until.blank? || version.effective_until > context.quoted_at
      end

      def program_active_at?(program)
        return false if program.blank? || !program.active
        return false if program.starts_at.present? && program.starts_at > context.quoted_at

        program.ends_at.blank? || program.ends_at > context.quoted_at
      end
    end
  end
end
