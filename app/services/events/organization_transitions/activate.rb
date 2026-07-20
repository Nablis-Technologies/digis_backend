# frozen_string_literal: true

module Events
  module OrganizationTransitions
    class Activate < Core::BaseService
      def initialize(organization:, actor:)
        @organization = organization
        @actor = actor
      end

      def call
        return permission_error unless Events::AuthorizationResolver.organization_admin_or_owner?(actor, organization.event)

        Events::Event.transaction do
          organization.lock!
          organization.update!(status: "active")
          organization.record_audit!("event.organization.activated", actor:)
          success(organization)
        end
      end

      private

      attr_reader :organization, :actor

      def permission_error
        failure Core::BusinessError.new(
          I18n.t("authorization.errors.unauthorized"),
          code: "forbidden",
          status: :forbidden
        )
      end
    end
  end
end
