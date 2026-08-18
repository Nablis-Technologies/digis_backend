# frozen_string_literal: true

module Ticketing
  # Claim lifecycle metadata without raw token, token digest, or contact
  # digest. The one-time plaintext is returned only by the invite command.
  class CredentialClaimSerializer < ActiveModel::Serializer
    attributes :id, :credential_id, :invited_user_id, :claimed_by_user_id,
               :status, :expires_at, :accepted_at, :created_at, :updated_at
  end
end
