# frozen_string_literal: true

module Events
  module StaffInvitations
    class Roster < Core::BaseService
      Page = Data.define(:records, :pagination)
      Result = Data.define(:assignments, :invitations)

      DEFAULT_PER_PAGE = 25
      MAX_PER_PAGE = 100

      def initialize(event:, assignments_page:, assignments_per_page:, invitations_page:, invitations_per_page:)
        @event = event
        @assignments_page = page_number(assignments_page)
        @assignments_per_page = per_page_number(assignments_per_page)
        @invitations_page = page_number(invitations_page)
        @invitations_per_page = per_page_number(invitations_per_page)
      end

      def call
        success(Result.new(
          assignments: build_page(assignment_scope, assignments_page, assignments_per_page),
          invitations: build_page(invitation_scope, invitations_page, invitations_per_page)
        ))
      end

      private

      attr_reader :event, :assignments_page, :assignments_per_page,
                  :invitations_page, :invitations_per_page

      def assignment_scope
        event.event_staff_assignments.where(
          role: %w[manager staff contractor],
          status: %w[active suspended]
        ).includes(:user, :organization).order(created_at: :desc, id: :desc)
      end

      def invitation_scope
        StaffInvitation.where(event_id: event.id, status: "pending").order(created_at: :desc, id: :desc)
      end

      def build_page(scope, page, per_page)
        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        Page.new(
          scope.limit(per_page).offset((page - 1) * per_page).to_a,
          {
            current_page: page,
            per_page:,
            total_count:,
            total_pages:
          }
        )
      end

      def page_number(value)
        parsed = Integer(value, 10)
        parsed.positive? ? parsed : 1
      rescue ArgumentError, TypeError
        1
      end

      def per_page_number(value)
        parsed = Integer(value, 10)
        parsed.positive? ? [ parsed, MAX_PER_PAGE ].min : DEFAULT_PER_PAGE
      rescue ArgumentError, TypeError
        DEFAULT_PER_PAGE
      end
    end
  end
end
