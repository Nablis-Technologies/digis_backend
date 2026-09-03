# frozen_string_literal: true

module Messaging
  module Providers
    # Persists visibility in the notification inbox; no external provider call
    # is needed once the notification and delivery rows are committed.
    class InApp < Adapter
      def deliver(notification:, delivery:, content:, idempotency_key:)
        DeliveryResult.delivered(provider: "internal")
      end
    end
  end
end
