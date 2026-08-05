# frozen_string_literal: true

require "test_helper"

class Core::LocalizedMessagesTest < ActiveSupport::TestCase
  test "catalog and ticketing command messages are defined in locales" do
    keys = %w[
      catalog.event_product.errors.active_immutable
      catalog.inventory.errors.product_not_active
      catalog.product_access.errors.duplicate
      catalog.product_date_allocation.errors.duplicate
      ticketing.ticket_type.errors.already_exists
    ]

    keys.each { |key| assert I18n.exists?(key), "missing locale key: #{key}" }
  end
end
