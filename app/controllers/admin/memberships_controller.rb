module Admin
  class MembershipsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController
    include Core::MembershipManagement

    self.parent_param = :organization_id
  end
end
