# frozen_string_literal: true

module Organizations
  module MembershipInvitations
    class Roster < Core::BaseService
      Page = Data.define(:records, :pagination)
      Result = Data.define(:memberships, :invitations)

      DEFAULT_PER_PAGE = 25
      MAX_PER_PAGE = 100

      def initialize(organization:, memberships_page:, memberships_per_page:, invitations_page:, invitations_per_page:)
        @organization = organization
        @memberships_page = page_number(memberships_page)
        @memberships_per_page = per_page_number(memberships_per_page)
        @invitations_page = page_number(invitations_page)
        @invitations_per_page = per_page_number(invitations_per_page)
      end

      def call
        success(Result.new(
          memberships: build_page(membership_scope, memberships_page, memberships_per_page),
          invitations: build_page(invitation_scope, invitations_page, invitations_per_page)
        ))
      end

      private

      attr_reader :organization, :memberships_page, :memberships_per_page,
                  :invitations_page, :invitations_per_page

      def membership_scope
        organization.memberships.where(status: %w[active suspended]).includes(:user)
          .order(created_at: :desc, id: :desc)
      end

      def invitation_scope
        MembershipInvitation.where(organization_id: organization.id, status: "pending")
          .order(created_at: :desc, id: :desc)
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
