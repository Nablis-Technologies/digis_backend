# frozen_string_literal: true

module Ticketing
  # Safe response policy for generation transition projections. Ticket access
  # remains owner-scoped; the serializer itself omits bearer secrets.
  class CredentialGenerationPolicy < Core::ApplicationPolicy
    FIELDS = %i[id ticket_id version mode status activated_at revoked_at revocation_reason created_at updated_at].freeze

    # The command has already authorized the ticket owner before returning
    # this transition projection; this policy only supplies safe fields.
    def show? = true

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [ :credentials ] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [ :credentials ] }, admin: { fields: :all, include: :all } },
      cancel: { default: { fields: FIELDS, include: [ :credentials ] }, admin: { fields: :all, include: :all } },
      reassign: { default: { fields: FIELDS, include: [ :credentials ] }, admin: { fields: :all, include: :all } }
    }.freeze
  end
end
