# frozen_string_literal: true

module Commercial
  module Entitlements
    # Reconciles the one-event benefit against committed publication facts.
    #
    # Publication delivery is at-least-once and may arrive out of order, so the
    # event being delivered is only a trigger. The authoritative event rows are
    # re-read while the organization row is locked; the earliest open qualifying
    # event by (published_at, id) owns the reservation. This same command is
    # intended for synchronous checkout reconciliation in a later task.
    class ReconcileFirstEvent < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(event:)
        @event = event
      end

      def call
        return failure(entitlement_error(:event_required)) unless event_id

        ActiveRecord::Base.transaction do
          source_event = event.respond_to?(:organization_id) ? event : Events::Event.find_by(id: event_id)
          return success(nil) unless source_event

          organization = Organizations::Organization.lock.find(source_event.organization_id)
          authoritative_event = Events::Event.find_by(id: event_id)
          return success(nil) unless published_event?(authoritative_event)

          reconcile_locked(authoritative_event, organization)
        end
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_record"),
            code: "invalid_record", status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          ).to_a
        )
      end

      private

      attr_reader :event

      def event_id
        event.respond_to?(:id) ? event.id : event.presence
      end

      def reconcile_locked(authoritative_event, organization)
        assignments = first_event_assignments(organization.id)
        @assignments = assignments
        selected = select_assignment_for(authoritative_event)
        return success(nil) if selected.nil?
        return failure(entitlement_error(:entitlement_ambiguous)) if selected == :ambiguous

        candidate, selection_error = earliest_candidate_event(
          organization:, selected_assignment: selected, at: Time.current
        )
        return failure(selection_error) if selection_error
        return success(nil) unless candidate

        program = selected.program
        entitlement = locked_entitlement(program:, organization:)
        return success(entitlement) if terminal?(entitlement)

        expire_due_reservation!(entitlement, program:, now: Time.current) if expired_reservation?(entitlement)
        return success(entitlement) if entitlement.status == "expired"
        return success(entitlement) if entitlement.status == "reserved" && entitlement.reserved_event_id == candidate.id
        return success(entitlement) if reservation_owned_by_later_event?(entitlement, candidate)

        reserve!(entitlement, program:, candidate:, at: Time.current)
      end

      def first_event_assignments(organization_id)
        Commercial::Assignment.joins(:program).preload(:program)
          .where(
            organization_id:,
            assignment_type: "program",
            status: %w[scheduled active],
            commercial_programs: {
              program_type: "first_monetized_event",
              enrollment_mode: "automatic",
              active: true
            }
          ).to_a
      end

      def select_assignment_for(candidate_event)
        matches = matching_assignments(candidate_event)
        return nil if matches.empty?

        event_specific = matches.select { |assignment| assignment.event_id == candidate_event.id }
        matches = event_specific if event_specific.any?
        programs = matches.map(&:program_id).uniq
        return :ambiguous if programs.length > 1

        matches.max_by { |assignment| [ assignment.effective_from, assignment.id ] }
      end

      def matching_assignments(candidate_event)
        @assignments.select do |assignment|
          assignment_matches_event?(assignment, candidate_event) &&
            assignment_active_at?(assignment, candidate_event.published_at) &&
            program_active_at?(assignment.program, candidate_event.published_at)
        end
      end

      def assignment_matches_event?(assignment, candidate_event)
        assignment.event_id.nil? || assignment.event_id == candidate_event.id
      end

      def assignment_active_at?(assignment, at)
        assignment.effective_from <= at &&
          (assignment.effective_until.nil? || assignment.effective_until > at)
      end

      def program_active_at?(program, at)
        (program.starts_at.nil? || program.starts_at <= at) &&
          (program.ends_at.nil? || program.ends_at > at)
      end

      def earliest_candidate_event(organization:, selected_assignment:, at:)
        events = candidate_events(organization:, selected_assignment:)
        events.each do |candidate_event|
          next unless open_event?(candidate_event, at:)

          selection = select_assignment_for(candidate_event)
          return [ nil, entitlement_error(:entitlement_ambiguous) ] if selection == :ambiguous
          return [ candidate_event, nil ] if selection&.program_id == selected_assignment.program_id
        end

        [ nil, nil ]
      end

      def candidate_events(organization:, selected_assignment:)
        scope = Events::Event.where(status: "published").where.not(published_at: nil)
          .preload(:event_dates).order(:published_at, :id)
        scope = scope.where(id: selected_assignment.event_id) if selected_assignment.event_id.present?
        scope = scope.where(organization_id: organization.id) if selected_assignment.event_id.blank?
        scope.to_a
      end

      def open_event?(candidate_event, at:)
        return false unless published_event?(candidate_event)
        return false if candidate_event.status.in?(%w[cancelled completed])

        dates = candidate_event.event_dates
        return true if dates.empty?

        dates.any? do |event_date|
          event_date.ends_at > at && !event_date.status.in?(%w[cancelled completed])
        end
      end

      def published_event?(candidate_event)
        candidate_event&.status == "published" && candidate_event.published_at.present?
      end

      def locked_entitlement(program:, organization:)
        Commercial::ProgramEntitlement.lock.find_by(
          program_id: program.id, organization_id: organization.id
        ) || Commercial::ProgramEntitlement.new(program:, organization:, status: "available", lock_version: 0)
      end

      def terminal?(entitlement)
        entitlement.persisted? && entitlement.status.in?(%w[consumed expired])
      end

      def expired_reservation?(entitlement)
        entitlement.persisted? && entitlement.status == "reserved" &&
          entitlement.expires_at.present? && entitlement.expires_at <= Time.current
      end

      def reservation_owned_by_later_event?(entitlement, candidate)
        return false unless entitlement.status == "reserved"
        return false unless entitlement.reserved_event_id
        return false if entitlement.reserved_event_id == candidate.id

        reserved_event = Events::Event.find_by(id: entitlement.reserved_event_id)
        reserved_event.present? &&
          (event_sort_key(reserved_event) <=> event_sort_key(candidate)) <= 0
      end

      def event_sort_key(candidate_event)
        [ candidate_event.published_at, candidate_event.id ]
      end

      def expire_due_reservation!(entitlement, program:, now:)
        before = entitlement.attributes.slice("status", "reserved_event_id", "reserved_at")
        entitlement.update!(
          status: "expired", reserved_event_id: nil, reserved_at: nil,
          consumed_at: nil, released_at: nil, expires_at: entitlement.expires_at || program.ends_at
        )
        record_transition!(
          target: entitlement, actor: nil,
          audit_key: "commercial-entitlement-expired-#{entitlement.id}-#{entitlement.lock_version}",
          action: "commercial.program_entitlement.expired",
          audited_changes: before.merge("status" => [ before.fetch("status"), "expired" ]),
          metadata: { "expired_at" => now, "program_id" => program.id },
          topic: "commercial", event_type: "commercial.program_entitlement.expired",
          payload: { program_entitlement_id: entitlement.id, program_id: program.id, status: "expired" }
        )
      end

      def reserve!(entitlement, program:, candidate:, at:)
        before = entitlement.attributes.slice("status", "reserved_event_id", "reserved_at")
        entitlement.assign_attributes(
          status: "reserved", reserved_event_id: candidate.id, reserved_at: at,
          consumed_at: nil, released_at: nil, expires_at: program.ends_at
        )
        entitlement.save!

        action = before["status"] == "reserved" ? "commercial.program_entitlement.reservation_replaced" : "commercial.program_entitlement.reserved"
        record_transition!(
          target: entitlement, actor: nil,
          audit_key: "commercial-entitlement-reserved-#{entitlement.id}-#{candidate.id}",
          action:,
          audited_changes: before.merge(
            "status" => [ before.fetch("status"), "reserved" ],
            "reserved_event_id" => [ before["reserved_event_id"], candidate.id ]
          ),
          metadata: {
            "program_id" => program.id,
            "organization_id" => candidate.organization_id,
            "source_event_id" => candidate.id,
            "source_published_at" => candidate.published_at
          },
          topic: "commercial", event_type: "commercial.program_entitlement.reserved",
          payload: {
            program_entitlement_id: entitlement.id, program_id: program.id,
            organization_id: candidate.organization_id, event_id: candidate.id, status: "reserved"
          }
        )
        success(entitlement)
      end

      def entitlement_error(key)
        Core::BusinessError.new(
          I18n.t("commercial.entitlements.errors.#{key}"),
          code: key.to_s, status: :unprocessable_entity
        )
      end
    end
  end
end
