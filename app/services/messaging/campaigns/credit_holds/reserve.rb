# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Campaign-specific name for the shared aggregate reservation command.
      class Reserve < Messaging::CreditAccounts::Reserve
      end
    end
  end
end
