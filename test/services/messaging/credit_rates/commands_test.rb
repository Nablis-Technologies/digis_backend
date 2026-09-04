# frozen_string_literal: true

require "test_helper"

module Messaging
  module CreditRates
    class CommandsTest < ActiveSupport::TestCase
      setup do
        @actor = core_users(:super_admin)
        @organization = organizations_organizations(:one)
        @attributes = {
          channel: "sms", currency: "ETB", unit_price_minor: 25,
          volume_tiers: [], effective_from: 1.hour.ago
        }
      end

      test "creates a draft rate and replays the same request" do
        operation = -> {
          Create.call(actor: @actor, attributes: @attributes, idempotency_key: "rate-create-1")
        }

        assert_idempotent(operation, counter: -> { CreditRateVersion.count })
        assert_equal "draft", operation.call.value.status
      end

      test "activates and retires a rate with audited transitions" do
        rate = Create.call(actor: @actor, attributes: @attributes, idempotency_key: "rate-create-2").value

        activated = Activate.call(rate:, actor: @actor, idempotency_key: "rate-activate-1")
        assert_predicate activated, :success?, activated.error&.message
        assert_equal "active", activated.value.status

        retired = Retire.call(rate: activated.value, actor: @actor, idempotency_key: "rate-retire-1")
        assert_predicate retired, :success?, retired.error&.message
        assert_equal "retired", retired.value.status
      end

      test "rejects activation when another active version overlaps" do
        first = Create.call(actor: @actor, attributes: @attributes, idempotency_key: "rate-create-3").value
        assert_predicate Activate.call(rate: first, actor: @actor, idempotency_key: "rate-activate-3"), :success?

        second = Create.call(
          actor: @actor,
          attributes: @attributes.merge(unit_price_minor: 30),
          idempotency_key: "rate-create-4"
        ).value
        result = Activate.call(rate: second, actor: @actor, idempotency_key: "rate-activate-4")

        assert_predicate result, :failure?
        assert_equal "rate_overlap", result.error.code
      end

      test "allows overlapping effective windows when currencies differ" do
        first = Create.call(actor: @actor, attributes: @attributes, idempotency_key: "rate-create-etb").value
        assert_predicate Activate.call(rate: first, actor: @actor, idempotency_key: "rate-activate-etb"), :success?

        second = Create.call(
          actor: @actor, attributes: @attributes.merge(currency: "USD"), idempotency_key: "rate-create-usd"
        ).value
        result = Activate.call(rate: second, actor: @actor, idempotency_key: "rate-activate-usd")

        assert_predicate result, :success?, result.error&.message
      end

      test "rejects activation-key reuse for another rate" do
        first = Create.call(actor: @actor, attributes: @attributes, idempotency_key: "rate-create-5").value
        second = Create.call(
          actor: @actor, attributes: @attributes.merge(channel: "email"), idempotency_key: "rate-create-6"
        ).value
        assert_predicate Activate.call(rate: first, actor: @actor, idempotency_key: "shared-activate"), :success?

        result = Activate.call(rate: second, actor: @actor, idempotency_key: "shared-activate")

        assert_predicate result, :failure?
        assert_equal "credit_idempotency_conflict", result.error.code
      end
    end
  end
end
