# frozen_string_literal: true

module Ticketing
  # Runs periodically so expired guest-list links cannot remain claimable.
  class ExpireInvitationsJob < ApplicationJob
    queue_as :default

    def perform
      Ticketing::Invitations::Expire.call
    end
  end
end
