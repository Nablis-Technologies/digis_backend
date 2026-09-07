# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Canonical identity for one delivery allocation against one campaign hold.
      module AllocationIdentity
        module_function

        def digest(reservation:, delivery:, quantity:)
          Core::KeyedDigest.digest(
            namespace: "messaging-campaign-allocation",
            value: "#{reservation.id}:#{delivery.id}:#{quantity}"
          )
        end
      end
    end
  end
end
