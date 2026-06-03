module Events
  class VenuesController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Events::Venue
    self.list_serializer = Events::Public::VenueListSerializer
    self.detail_serializer = Events::Public::VenueDetailSerializer

    private

    def base_scope
      Events::Venue.active.with_attached_profile.with_attached_photos
    end

    def detail_scope
      Events::Venue.with_attached_profile.with_attached_photos
    end

    def apply_catalog_filters(scope)
      scope = scope.by_city(params[:city]) if params[:city].present?
      scope = scope.by_country(params[:country]) if params[:country].present?
      scope = scope.verified if ActiveModel::Type::Boolean.new.cast(params[:verified])
      scope
    end

    def allowed_order_columns
      %w[id name city country created_at]
    end
  end
end
