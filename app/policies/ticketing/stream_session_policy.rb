# frozen_string_literal: true

module Ticketing
  # Keeps playback sessions owner-scoped and prevents generic API responses
  # from exposing token digests or provider playback material.
  class StreamSessionPolicy < Core::ApplicationPolicy
    FIELDS = %i[id ticket_id event_stream_id user_id device_id status expires_at last_seen_at revoked_at created_at updated_at].freeze

    def create?
      user.present? && record.ticket&.owner_user_id == user.id
    end

    def refresh? = owner?
    def revoke? = owner?

    VISIBILITY = {
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      refresh: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } },
      revoke: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: [] } }
    }.freeze

    private

    def owner?
      user.present? && record.user_id == user.id
    end
  end
end
