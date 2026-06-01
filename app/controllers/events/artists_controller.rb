module Events
  class ArtistsController < ::Public::ApplicationController
    include Core::PublicCommon
    include Core::FollowableActions

    self.model_class = Events::Artist
    self.list_serializer = Events::Public::ArtistListSerializer
    self.detail_serializer = Events::Public::ArtistDetailSerializer

    private

    def base_scope
      Events::Artist.active.with_attached_profile
    end

    def detail_scope
      Events::Artist.with_attached_profile
    end

    def apply_catalog_filters(scope)
      scope = scope.by_genre(params[:genre]) if params[:genre].present?
      scope = scope.verified if params[:verified] == "true"
      scope
    end

    def allowed_order_columns
      %w[id name created_at]
    end

    def followable_class
      Events::Artist
    end
  end
end
