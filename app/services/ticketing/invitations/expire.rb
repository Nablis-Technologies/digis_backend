# frozen_string_literal: true

module Ticketing
  module Invitations
    # Marks pending invitations past their expiry window as expired.
    class Expire < Core::BaseService
      def call(at: Time.current)
        count = Ticketing::Invitation
          .where(status: "pending")
          .where("expires_at IS NOT NULL AND expires_at <= ?", at)
          .update_all(status: "expired", updated_at: at)

        success(count)
      end
    end
  end
end
