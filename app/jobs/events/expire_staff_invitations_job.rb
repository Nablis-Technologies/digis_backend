# frozen_string_literal: true

module Events
  class ExpireStaffInvitationsJob < ApplicationJob
    queue_as :default

    def perform(limit: Events::StaffInvitations::Expire::DEFAULT_BATCH_SIZE)
      result = Events::StaffInvitations::Expire.call(limit:)
      raise result.error if result.failure?

      result.value
    end
  end
end
