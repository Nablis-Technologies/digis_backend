# frozen_string_literal: true

module Organizations
  class ExpireMembershipInvitationsJob < ApplicationJob
    queue_as :default

    def perform(limit: Organizations::MembershipInvitations::Expire::DEFAULT_BATCH_SIZE)
      result = Organizations::MembershipInvitations::Expire.call(limit:)
      raise result.error if result.failure?

      result.value
    end
  end
end
