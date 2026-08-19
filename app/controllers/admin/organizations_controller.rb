module Admin
  class OrganizationsController < Admin::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Organizations::Organization
    self.default_serializer = ::Admin::OrganizationSerializer

    auditable on: %i[create update destroy transfer_ownership]

    before_action :set_download_object, only: :download

    def create
      unless params.dig(:organization, :owner_id)
        return render_error(:"admin.organizations.errors.owner_id_required",
                            status: :unprocessable_entity)
      end
      super
    end

    def destroy
      @obj.memberships.delete_all
      super
    end

    # Private verification documents are delivered only after authorization;
    # the signed redirect is intentionally absent from organization JSON.
    def download
      authorize @obj, :download_documents?
      attachment = document_attachment
      return render_error(I18n.t("organization.errors.document_not_found"), status: :not_found) unless attachment&.attached?

      redirect_to rails_blob_url(attachment, disposition: "inline", expires_in: 5.minutes)
    end

    def transfer_ownership
      set_object
      authorize @obj, :transfer_ownership?

      new_owner = Core::User.find_by(id: params.dig(:organization, :new_owner_id))
      unless new_owner
        return render_error(:"admin.organizations.errors.new_owner_id_invalid",
                            status: :unprocessable_entity)
      end

      ActiveRecord::Base.transaction do
        @obj.with_lock do
          current_owner_membership = @obj.owner_membership
          return render_error(:"admin.organizations.errors.no_current_owner",
                              status: :unprocessable_entity) unless current_owner_membership

          # Demote the old owner first, bypassing the sole-owner callback via update_column
          current_owner_membership.update_column(:role, :admin)

          target_membership = @obj.memberships.lock.find_by(user: new_owner)
          if target_membership
            target_membership.update!(role: :owner)
          else
            begin
              @obj.memberships.create!(user: new_owner, role: :owner)
            rescue ActiveRecord::RecordNotUnique
              target_membership = @obj.memberships.lock.find_by(user: new_owner)
              raise unless target_membership
              target_membership.update!(role: :owner)
            end
          end
        end
      end

      @obj = @clazz.includes(eager_loaded_associations).find(@obj.id)
      render_success(data: @obj, serializer_options: { serializer: ::Admin::OrganizationSerializer })
    end

    private

    def serializer_profile
      {
        index:  { include: %i[owner] },
        show:   { include: %i[owner] },
        create: { include: %i[owner] },
        update: { include: %i[owner] }
      }
    end

    def eager_load_config
      { default: [ :memberships, :reviews,
                   { owner_membership: :user,
                     profile_attachment: :blob,
                     banner_attachment: :blob,
                     business_license_attachment: :blob,
                     tin_certificate_attachment: :blob } ] }
    end

    def allowed_order_columns
      %w[id name slug created_at updated_at]
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

    def document_attachment
      case params[:document_type]
      when "business_license" then @obj.business_license
      when "tin_certificate" then @obj.tin_certificate
      end
    end

    def set_download_object
      set_object
    end

    def after_create_hook(organization)
      owner = Core::User.find(params.dig(:organization, :owner_id))
      organization.memberships.create!(user: owner, role: :owner, status: :active)
    end
  end
end
