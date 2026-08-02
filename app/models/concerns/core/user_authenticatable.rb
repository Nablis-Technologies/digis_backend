module Core
  module UserAuthenticatable
    extend ActiveSupport::Concern

  included do
    has_secure_password validations: false

      has_many :refresh_tokens,
               class_name: "Core::RefreshToken",
               foreign_key: :user_id,
               dependent: :destroy,
               inverse_of: :user

      validates :email, uniqueness: true, allow_blank: true
      validates :phone, uniqueness: true, allow_blank: true
      validate :email_or_phone_present

      before_validation :normalize_identity_fields
    end

    def authenticate_with_password(password)
      authenticate(password)
    end

    def generate_auth_tokens(request)
      Core::AuthService.call(
        operation: :generate_auth_tokens,
        user: self,
        request: request
      ).value
    end

    def valid_for_authentication?
      active? && !locked?
    end

    def active?
      true
    end

    def locked?
      false
    end

    def revoke_all_tokens
      Core::AuthService.call(operation: :revoke_all_user_tokens, user: self)
    end

    def track_device(request)
      {
        user_agent: request.user_agent,
        ip_address: request.remote_ip,
        device_id: request.params[:device_id]
      }
    end

    private

    def normalize_identity_fields
      self.email = email.to_s.strip.downcase.presence
      self.phone = phone.to_s.strip.presence
    end

    def email_or_phone_present
      return unless email.blank? && phone.blank?

      errors.add(:base, I18n.t("user.errors.email_or_phone_required"))
    end
  end
end
