# frozen_string_literal: true

require "test_helper"

module Marketplace
  class MultiAcquisitionCancellationTest < ActionDispatch::IntegrationTest
    include AcquisitionChainTestHelpers

    class CancellationRefundAdapter < Payments::Providers::Adapter
      attr_reader :refund_requests

      def initialize
        @refund_requests = []
      end

      def refund(**request)
        refund_requests << request
        Payments::Providers::Result.success(provider_reference: "chain-refund-#{refund_requests.length}")
      end

      def verify_refund(**)
        Payments::Providers::Result.success(provider_reference: "chain-refund-verified")
      end

      def available_balance(**)
        { amount_minor: 10_000, currency: "ETB" }
      end

      def capabilities
        { refunds: { supported: true, partial: true, fee_estimate_minor: 0 } }
      end
    end

    setup do
      setup_acquisition_chain_context
    end

    test "keeps immutable ownership history while cancelling the whole acquisition chain" do
      original_owner_id = @owner.id
      first_buyer_id = @buyer.id
      current_buyer_id = @second_buyer.id
      original_generation_count = Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count

      result = CancelAcquisitionChainValue.call(
        ticket: @ticket,
        idempotency_key: "integration-cancel-chain-#{@ticket.id}"
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal original_owner_id, @first_sale.seller_user_id
      assert_equal first_buyer_id, @first_sale.buyer_user_id
      assert_equal current_buyer_id, @second_sale.buyer_user_id
      assert_equal original_generation_count, Ticketing::CredentialGeneration.where(ticket_id: @ticket.id).count
      assert_equal current_buyer_id, @ticket.reload.owner_user_id
      assert_equal "resale_purchase", @ticket.current_acquisition_type
      assert_equal 3, Orders::Refund.where(
        payment_id: [ @primary_payment.id, @payment.id, @second_payment.id ]
      ).count
    end

    test "event cancellation routes each acquisition chain through one refund boundary" do
      adapter = CancellationRefundAdapter.new
      Payments::Providers::Registry.register("chapa", adapter)
      cancellation = Events::Cancellation::Initiate.call(
        event: @event,
        actor: @manager,
        attendee_reason: "The event will not proceed.",
        idempotency_key: "chain-event-cancellation-#{SecureRandom.hex(5)}"
      ).value
      cancellation.update!(
        status: "processing",
        total_payments_count: 3,
        refunds_started_at: Time.current
      )
      [ @primary_payment, @payment, @second_payment ].each do |payment|
        Events::EventCancellationPayment.create!(event_cancellation: cancellation, payment:)
      end

      result = Events::Cancellation::ProcessPayment.call(cancellation:, now: Time.current)

      assert_predicate result, :success?, result.error&.message
      assert_equal 3, Orders::Refund.where(event_cancellation: cancellation).count
      assert_equal 1, adapter.refund_requests.length
      assert_equal "cancelled", @first_sale.reload.status
      assert_equal "cancelled", @second_sale.reload.status
    ensure
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end
  end
end
