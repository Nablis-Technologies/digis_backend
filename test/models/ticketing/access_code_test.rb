# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AccessCodeTest < ActiveSupport::TestCase
    setup do
      @ticket_type = create_ticket_product.ticket_type
    end

    test "code_digest is required and unique per ticket type" do
      raw = "ABC123"
      digest = Ticketing::AccessCode.code_digest_for(event_id: @ticket_type.event_product.event_id, code: raw)
      Ticketing::AccessCode.create!(
        ticket_type: @ticket_type, code_digest: digest, max_quantity_per_use: 1
      )
      duplicate = Ticketing::AccessCode.new(ticket_type: @ticket_type, code_digest: digest)
      assert duplicate.invalid?
      assert_includes duplicate.errors[:code_digest], "already used for this ticket type"
    end

    test "max_uses and max_quantity_per_use must be at least 1" do
      code = Ticketing::AccessCode.new(
        ticket_type: @ticket_type,
        code_digest: "x",
        max_uses: 0,
        max_quantity_per_use: 0
      )
      assert code.invalid?
      assert_includes code.errors[:max_uses], "must be greater than or equal to 1"
      assert_includes code.errors[:max_quantity_per_use], "must be greater than or equal to 1"
    end

    test "used_count must be non-negative" do
      code = Ticketing::AccessCode.new(
        ticket_type: @ticket_type, code_digest: "x", used_count: -1
      )
      assert code.invalid?
      assert_includes code.errors[:used_count], "must be greater than or equal to 0"
    end

    test "expires_at must be after starts_at" do
      code = Ticketing::AccessCode.new(
        ticket_type: @ticket_type, code_digest: "x",
        starts_at: 2.days.from_now, expires_at: 1.day.from_now
      )
      assert code.invalid?
      assert_includes code.errors[:expires_at], "must be after starts_at"
    end

    private

    def create_ticket_product
      Catalog::Products::CreateDraft.call(
        event: events_events(:ready_listing),
        actor: core_users(:super_admin),
        product_attributes: { name: "VIP", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
    end
  end
end
