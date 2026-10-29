module Organizations
  class OrganizationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer
    include Rails.application.routes.url_helpers

    attributes :id, :name, :slug, :description, :social_links,
               :organizer_type, :category,
               :contact_phone, :contact_email, :website_url,
               :tin_number, :address_line1, :address_line2, :city, :region,
               :estimated_audience, :event_frequency,
                :events_count, :follower_count, :memberships_count,
                :verified, :is_following, :verification_status, :verification_feedback,
                :has_business_license, :has_tin_certificate,
                :membership_status, :membership_role, :archived,
               :created_at

    attribute :follower_count do
      object.followers_count
    end

    attribute :memberships_count do
      object.memberships.size
    end

    attribute :verified do
      object.verified?
    end

    attribute :is_following do
      if instance_options[:current_user]
        object.followed_by?(instance_options[:current_user])
      else
        false
      end
    end

    attribute :profile_url do
      object.profile.attached? ? url_for(object.profile) : nil
    end

    attribute :banner_url do
      object.banner.attached? ? url_for(object.banner) : nil
    end

    def verification_status
      return unless verification_fields_visible?

      current_verification_review&.status || "draft"
    end

    def verification_feedback
      return unless verification_fields_visible?

      current_verification_review&.feedback
    end

    def has_business_license
      return unless verification_fields_visible?

      object.business_license.attached?
    end

    def has_tin_certificate
      return unless verification_fields_visible?

      object.tin_certificate.attached?
    end

    def membership_status
      return unless membership_summary_visible?

      current_membership&.status
    end

    def membership_role
      return unless membership_summary_visible?

      current_membership&.role
    end

    def archived
      return unless membership_summary_visible?

      object.archived?
    end

    private

    def current_membership
      return @current_membership if defined?(@current_membership)
      return unless membership_summary_visible?

      current_user = instance_options[:current_user]
      memberships = object.association(:memberships)
      @current_membership = if current_user && memberships.loaded?
        memberships.target.find { |membership| membership.user_id == current_user.id }
      end
    end

    def membership_summary_visible?
      visible_fields = instance_options[:visible_attributes]
      visible_fields&.map(&:to_sym)&.include?(:membership_status)
    end

    def current_verification_review
      return @current_verification_review if defined?(@current_verification_review)

      @current_verification_review = object.current_review_for(:verification)
    end

    def verification_fields_visible?
      visible_fields = instance_options[:visible_attributes]
      return false if visible_fields && !visible_fields.map(&:to_sym).include?(:verification_status)

      current_user = instance_options[:current_user]
      return false unless current_user
      return true if platform_admin?(current_user)

      memberships = object.association(:memberships)
      return false unless memberships.loaded?

      memberships.target.any? do |membership|
        membership.user_id == current_user.id && membership.status == "active" &&
          membership.role.in?(%w[owner admin])
      end
    end

    def platform_admin?(user)
      %w[SUPER_ADMIN ADMIN CORE_ADMIN].any? { |role| user.has_role?(role) }
    end
  end
end
