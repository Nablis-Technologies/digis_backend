module Admin
  class ArtistsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Artist

    auditable on: %i[create update destroy]

    private

    def allowed_order_columns
      %w[id name created_at updated_at]
    end

    def apply_index_scope(scope)
      scope.with_attached_profile
    end

    def model_params
      params.require(:artist).permit(
        :name, :description, :image_url, :verified, :active,
        :profile, genres: [], social_links: {}
      )
    end
  end
end
