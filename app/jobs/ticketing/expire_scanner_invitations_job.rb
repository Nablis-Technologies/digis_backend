# frozen_string_literal: true

module Ticketing
  class ExpireScannerInvitationsJob < ApplicationJob
    queue_as :default

    def perform(limit: Ticketing::Scanners::ExpireInvitations::DEFAULT_LIMIT, at: Time.current)
      result = Ticketing::Scanners::ExpireInvitations.call(limit:, at:)
      raise result.error if result.failure?

      result.value
    end
  end
end
