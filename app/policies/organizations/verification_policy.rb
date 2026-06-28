module Organizations
  class VerificationPolicy < Core::ApplicationPolicy
    def submit?
      owner_or_admin?
    end

    def resubmit?
      owner_or_admin?
    end

    private

    def owner_or_admin?
      user.present? && record.memberships.active.where(user: user).where.not(role: :staff).exists?
    end

    VISIBILITY = {
      submit: { admin: { include: :all, fields: :all }, default: { include: [], fields: :all } },
      resubmit: { admin: { include: :all, fields: :all }, default: { include: [], fields: :all } }
    }
  end
end
