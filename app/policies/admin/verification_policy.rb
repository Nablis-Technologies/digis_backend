module Admin
  class VerificationPolicy < Core::ApplicationPolicy
    def approve?
      user&.super_admin? || user&.has_permission?("verifications.approve")
    end

    def reject?
      user&.super_admin? || user&.has_permission?("verifications.reject")
    end

    def request_modification?
      user&.super_admin? || user&.has_permission?("verifications.request_modification")
    end

    VISIBILITY = {
      approve: { admin: { include: :all, fields: :all }, default: { include: [], fields: [] } },
      reject: { admin: { include: :all, fields: :all }, default: { include: [], fields: [] } },
      request_modification: { admin: { include: :all, fields: :all }, default: { include: [], fields: [] } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
