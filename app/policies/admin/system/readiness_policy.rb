# frozen_string_literal: true

module Admin
  module System
    # Restricts dependency readiness to platform administrators. Organizers
    # and ordinary authenticated users receive no infrastructure details.
    class ReadinessPolicy < Core::ApplicationPolicy
      def show?
        user&.super_admin? || user&.has_role?("CORE_ADMIN")
      end
    end
  end
end
