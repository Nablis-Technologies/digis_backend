# frozen_string_literal: true

module Catalog
  # Hands product lifecycle notifications to the future messaging adapter.
  class NotifyProductStatusChangedJob < ApplicationJob
    queue_as :default

    def perform(product_id, event_type)
      product = Catalog::EventProduct.find_by(id: product_id)
      return unless product

      sender = Rails.application.config.x.catalog_notification_sender
      return unless sender.respond_to?(:call)

      sender.call(product:, event_type:)
    end
  end
end
