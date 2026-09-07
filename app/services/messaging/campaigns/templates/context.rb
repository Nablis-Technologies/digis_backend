# frozen_string_literal: true

module Messaging
  module Campaigns
    module Templates
      # Builds the same campaign context for quoting and provider delivery.
      module Context
        module_function

        def values(campaign:, recipient: nil)
          values = campaign.variables.to_h.stringify_keys
          values["first_name"] = recipient.first_name if recipient&.first_name.present?
          values["organization_name"] = campaign.organization.name if campaign.organization
          values["event_name"] = campaign.event.title if campaign.event
          values
        end
      end
    end
  end
end
