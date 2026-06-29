module Core
  class RefreshToken < Core::ApplicationRecord
    belongs_to :user,
               class_name: "Core::User",
               inverse_of: :refresh_tokens

    validates :token_fingerprint, presence: true, uniqueness: true
    validates :expires_at, presence: true

    scope :active, -> { where(revoked: false).where("expires_at > ?", Time.current) }
    scope :revoked, -> { where(revoked: true) }
    scope :for_device, ->(device_id) { where(device_id: device_id) }

    before_validation :set_token_and_expiry, on: :create

    attr_accessor :raw_token

    def active?
      !revoked? && !expired?
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def revoked?
      revoked
    end

    def revoke!
      update(revoked: true, revoked_at: Time.current)
    end

    def self.generate(user, request)
      create!(
        user: user,
        jti: SecureRandom.uuid,
        device_id: request.params[:device_id].presence,
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
    end

    def self.find_valid(token)
      active.includes(:user).find_by(token_fingerprint: fingerprint_token(token))
    end

    def self.fingerprint_token(token)
      Digest::SHA256.hexdigest(token)
    end

    private

    def set_token_and_expiry
      self.raw_token ||= SecureRandom.hex(32)
      self.token_fingerprint = self.class.fingerprint_token(raw_token)
      self.expires_at ||= Core::TokenService.refresh_token_expires_in.from_now
    end
  end
end
