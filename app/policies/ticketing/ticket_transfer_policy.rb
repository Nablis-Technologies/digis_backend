# frozen_string_literal: true

module Ticketing
  # Transfer history is visible only to the original owner, recipient, or
  # initiator. The token digest is never included in the response fields.
  class TicketTransferPolicy < Core::ApplicationPolicy
    FIELDS = %i[
      id ticket_id from_user_id to_user_id initiated_by_id status previous_version new_version
      reason expires_at accepted_at declined_at cancelled_at created_at updated_at
    ].freeze

    # Transfer access is enforced by the lifecycle command; this policy only
    # supplies serializer visibility for its already-authorized response.
    def show? = true

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      accept: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      decline: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      cancel: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze
  end
end
