# frozen_string_literal: true

require_relative "fee_definition_test_helpers"

module Commercial
  # Builds the smallest real Commercial/Orders graph needed by subsidy
  # reservation tests. The helper intentionally creates no seeds because an
  # order-linked reservation is checkout evidence, not reference data.
  module SubsidyReservationTestHelpers
    include Commercial::FeeDefinitionTestHelpers

    def setup_subsidy_reservation_context(limit_minor: 1_000, subsidy_minor: 500,
      currency: "ETB", buyer: core_users(:attendee))
      @organization = organizations_organizations(:two)
      @event = events_events(:draft_concert)
      @schedule = create_schedule(code: "subsidy_#{SecureRandom.hex(5)}")
      @version = create_version(@schedule)
      @component = create_subsidy_component(@version, currency:)
      @assignment = Commercial::Assignment.create!(
        organization: @organization,
        fee_schedule_version: @version,
        assignment_type: "mutual_agreement",
        status: "draft",
        reason: "Subsidy reservation test agreement",
        effective_from: 1.day.ago,
        risk_level: "low",
        created_by: core_users(:super_admin)
      )
      @budget = Commercial::SubsidyBudget.create!(
        assignment: @assignment,
        fee_component: @component,
        currency:,
        limit_minor:
      )
      @order = create_order(currency:, subsidy_minor:, buyer:)
    end

    def create_subsidy_component(version, currency: nil)
      create_component(
        version,
        component_type: "platform_subsidy",
        calculation_type: "percentage",
        charged_to: "buyer",
        funded_by: "platform",
        basis_type: "eligible_order_subtotal",
        rate_bps: 1_000,
        offset_component_type: "buyer_service_fee",
        currency:,
        label: "Platform subsidy"
      )
    end

    def create_order(currency: "ETB", subsidy_minor: 500, buyer: core_users(:attendee),
      status: "draft", expires_at: 10.minutes.from_now)
      subtotal_minor = 10_000
      total_minor = subtotal_minor - subsidy_minor
      Orders::Order.create!(
        event: @event,
        buyer_user: buyer,
        sales_channel: "online",
        status:,
        charge_currency: currency,
        subtotal_minor:,
        discount_minor: 0,
        subsidy_minor:,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor:,
        settlement_currency: currency,
        settlement_total_minor: total_minor,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: expires_at,
        expires_at:,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
    end

    def build_reservation(attributes = {})
      Commercial::SubsidyReservation.new(
        {
          subsidy_budget: @budget,
          order: @order,
          idempotency_key_digest: "a" * 64,
          request_fingerprint: "b" * 64,
          amount_minor: 500,
          currency: "ETB",
          status: "held",
          expires_at: 10.minutes.from_now
        }.merge(attributes)
      )
    end
  end
end
