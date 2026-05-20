module Core
  class RefreshToken < Core::ApplicationRecord
    belongs_to :user,
               class_name: "Core::User",
               inverse_of: :refresh_tokens

    validates :refresh_token, presence: true, uniqueness: true
    validates :expires_at, presence: true

    scope :active, -> { where("expires_at > ?", Time.current) }
    scope :for_device, ->(device_id) { where(device_id: device_id) }

    before_validation :set_token_and_expiry, on: :create

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def self.generate(user, request)
      create!(
        user: user,
        device_id: request.params[:device_id].presence,
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
    end

    private

    def set_token_and_expiry
      self.refresh_token ||= SecureRandom.hex(32)
      self.expires_at ||= Core::TokenService.refresh_token_expires_in.from_now
    end
  end
end
