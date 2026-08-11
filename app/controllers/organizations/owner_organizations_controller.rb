module Organizations
  class OwnerOrganizationsController < Organizations::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Organization

    auditable on: %i[create update destroy]

    before_action :set_object, only: %i[show update destroy documents download]

    def destroy
      authorize @obj
      if @obj.legal_acceptances.exists? || organization_has_orders?
        @obj.update!(archived: true)
        render_success(status: :ok)
      else
        @obj.memberships.delete_all
        @obj.destroy!
        render_success(status: :ok)
      end
    end

    def set_object
      @obj = @clazz.joins(:memberships)
                   .where(organizations_memberships: { user_id: current_user.id, status: :active })
                   .includes(eager_loaded_associations)
                   .find(params[:id])
    end

    def documents
      authorize @obj, :update?
      failed = []
      failed << :profile unless !params[:profile] || @obj.profile.attach(params[:profile])
      failed << :banner unless !params[:banner] || @obj.banner.attach(params[:banner])
      failed << :business_license unless !params[:business_license] || @obj.business_license.attach(params[:business_license])
      failed << :tin_certificate unless !params[:tin_certificate] || @obj.tin_certificate.attach(params[:tin_certificate])
      return render_error(I18n.t(:"organization.errors.documents", failed: failed.join(", ")), status: :unprocessable_entity) if failed.any?

      render_success(data: @obj)
    end

    def download
      authorize @obj, :download_documents?
      attachment = document_attachment
      return render_error(status: :unprocessable_entity) unless attachment

      redirect_to rails_blob_url(attachment, disposition: "inline", expires_in: 5.minutes)
    end

    private

    def document_attachment
      case params[:document_type]
      when "banner" then @obj.banner
      when "business_license" then @obj.business_license
      when "tin_certificate" then @obj.tin_certificate
      when "profile" then @obj.profile
      end
    end

    def apply_index_scope(scope)
      scope.joins(:memberships)
           .where(organizations_memberships: { user_id: current_user.id })
    end

    def model_params
      params.require(:organization).permit(
        :name, :description, :organizer_type, :category,
        :contact_phone, :contact_email, :website_url,
        :tin_number, :address_line1, :address_line2, :city, :region,
        :estimated_audience, :event_frequency,
        social_links: {}
      )
    end

    def allowed_order_columns
      %w[id name slug created_at updated_at]
    end

    def after_create_hook(organization)
      organization.memberships.create!(user: current_user, role: :owner, status: :active)
    end

    def organization_has_orders?
      klass = "Orders::Order".safe_constantize
      return false unless klass

      # Orders are scoped to one event; organization ownership is reached
      # through that event instead of being duplicated on the order row.
      klass.joins(:event).where(events_events: { organization_id: @obj.id }).exists?
    end

    def serializer_profile
      {
        index: { fields: %i[id name slug description profile_url
                            city region events_count follower_count
                            memberships_count verified created_at] },
        show: { fields: %i[id name slug description profile_url banner_url
                           business_license_url tin_certificate_url
                           social_links follower_count memberships_count
                           organizer_type category contact_phone contact_email website_url
                           tin_number address_line1 address_line2 city region
                           estimated_audience event_frequency
                           events_count verified is_following created_at] },
        create: { fields: %i[id name slug description created_at] },
        update: { fields: %i[id name slug description created_at] }
      }
    end

    def eager_load_config
      { default: [ :memberships, :reviews, :follows,
                   { profile_attachment: :blob,
                     banner_attachment: :blob,
                     business_license_attachment: :blob,
                     tin_certificate_attachment: :blob } ] }
    end
  end
end
