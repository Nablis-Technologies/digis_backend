module Admin
  class VenuesController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::Venue

    auditable on: %i[create update destroy]

    private

    def allowed_order_columns
      %w[id name created_at updated_at]
    end

    def apply_index_scope(scope)
      scope.with_attached_profile.with_attached_photos
    end

    def model_params
      params.require(:venue).permit(
        :name, :description, :address, :city, :country,
        :latitude, :longitude, :capacity, :contact_phone,
        :contact_email, :website_url, :verified, :active,
        :profile, photos: [], amenities: [], social_links: {}
      )
    end
  end
end
