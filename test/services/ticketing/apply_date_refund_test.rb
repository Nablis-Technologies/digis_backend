# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ApplyDateRefundTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 2)
      @second_date = @event.event_dates.create!(
        starts_at: 3.days.from_now,
        ends_at: 3.days.from_now + 4.hours,
        status: "scheduled"
      )
      @product.product_accesses.create!(event_date: @second_date, type: "venue", usage_limit: 1)
      @first_date = @product.product_accesses.first.event_date
      @product.product_date_allocations.create!(event_date: @first_date, allocation_basis_points: 5_000)
      @product.product_date_allocations.create!(event_date: @second_date, allocation_basis_points: 5_000)
      @payment = create_payment_for(@ticket.order_item)
    end

    test "replaces the active group generation excluding the refunded date" do
      refund = create_date_refund

      result = ApplyDateRefund.call(refund:)

      assert_predicate result, :success?, result.error&.message
      generation = result.value
      claims = Ticketing::Qr::Verifier.call(
        token: generation.credentials.sole.qr_token
      ).value

      assert_equal 2, generation.version
      assert_equal "group", generation.mode
      assert_equal [ @second_date.id.to_s ], generation.excluded_event_date_ids
      assert_equal [ @product.product_accesses.find_by!(event_date: @first_date).id.to_s ], claims.accesses
      assert_equal "revoked", Ticketing::CredentialGeneration.find_by!(ticket: @ticket, version: 1).status
    end

    test "preserves delegated assignments while excluding the refunded date" do
      delegated = Ticketing::Delegations::Activate.call(
        ticket: @ticket,
        actor: @owner,
        assignments: { 1 => @recipient, 2 => nil },
        idempotency_key: "delegated-before-date-refund"
      )
      assert_predicate delegated, :success?, delegated.error&.message
      refund = create_date_refund

      result = ApplyDateRefund.call(refund:)

      assert_predicate result, :success?, result.error&.message
      generation = result.value
      credentials = generation.credentials.includes(:admission_slot).index_by { |credential|
        credential.admission_slot.position
      }

      assert_equal "delegated", generation.mode
      assert_equal @recipient.id, credentials.fetch(1).holder_user_id
      assert_nil credentials.fetch(2).holder_user_id
      assert_equal [ @second_date.id.to_s ], generation.excluded_event_date_ids
    end

    test "is idempotent when the processing refund is retried" do
      refund = create_date_refund

      first = ApplyDateRefund.call(refund:)
      replay = ApplyDateRefund.call(refund:)

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal 2, Ticketing::CredentialGeneration.where(ticket: @ticket).count
    end

    test "restores the refunded date through a newer generation after provider failure" do
      refund = create_date_refund
      applied = ApplyDateRefund.call(refund:)
      refund.update!(status: "failed")

      result = RestoreFailedDateRefund.call(refund:)

      assert_predicate applied, :success?, applied.error&.message
      assert_predicate result, :success?, result.error&.message
      generation = result.value
      claims = Ticketing::Qr::Verifier.call(
        token: generation.credentials.sole.qr_token
      ).value

      assert_equal 3, generation.version
      assert_empty generation.excluded_event_date_ids
      assert_equal @product.product_accesses.map { |access| access.id.to_s }.sort, claims.accesses.sort
      assert_equal "revoked", Ticketing::CredentialGeneration.find_by!(ticket: @ticket, version: 2).status
    end

    private

    def create_date_refund
      result = Orders::CreateItemRefund.call(
        payment: @payment,
        order_item: @ticket.order_item,
        ticket: @ticket,
        event_date: @second_date,
        quantity: 1,
        reason_code: "schedule_change",
        idempotency_key: "date-refund-#{SecureRandom.hex(8)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value.tap { |refund| refund.update!(status: "processing") }
    end

    def create_payment_for(item)
      order = item.order
      Orders::Payment.create!(
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor: order.total_minor,
        currency: order.charge_currency,
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: "provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current,
        succeeded_at: Time.current,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: order.expires_at + 5.minutes
      )
    end
  end
end
