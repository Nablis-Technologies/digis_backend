module Organizations
  class OrganizationsController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Organizations::Organization
    self.list_serializer = Organizations::Public::OrganizationListSerializer
    self.detail_serializer = Organizations::Public::OrganizationDetailSerializer

    private

    def base_scope
      Organizations::Organization.all.with_attached_profile
    end

    def detail_scope
      Organizations::Organization.with_attached_profile
    end

    def searchable?
      true
    end

    def allowed_order_columns
      %w[id name slug created_at]
    end
  end
end
