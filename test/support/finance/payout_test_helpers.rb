# frozen_string_literal: true

module Finance
  # Creates deterministic immutable ledger facts for payout command tests. The
  # helper deliberately bypasses payment posting so each test can isolate one
  # maturity, allocation, or provider-reserve invariant.
  module PayoutTestHelpers
    include LedgerTestHelpers

    private

    def setup_payout_context(status: "completed", completed_at: nil)
      @now = Time.utc(2026, 8, 13, 12, 0, 0)
      suffix = SecureRandom.hex(6)
      @organization = Organizations::Organization.create!(
        name: "Payout Test Organization #{suffix}",
        slug: "payout-test-organization-#{suffix}",
        organizer_type: "company",
        category: "music"
      )
      @payout_account = Finance::PayoutAccount.create!(
        organization: @organization,
        type: "bank",
        provider: "chapa",
        bank_code: 128,
        account_number: "1000000000001",
        account_name: "Payout Test Organizer",
        account_label: "Payout test destination",
        account_number_digest: Core::KeyedDigest.digest(
          namespace: @organization.id, value: "1000000000001"
        ),
        status: "verified",
        verification_source: "test_fixture",
        verified_at: @now,
        is_default: true
      )
      @event = Events::Event.create!(
        organization: @organization,
        created_by: core_users(:super_admin),
        slug: "payout-test-event-#{suffix}",
        title: "Payout Test Event #{suffix}",
        visibility: "public",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        status: "published",
        published_at: Time.current
      )
      @event.update_columns(
        status:, completed_at:, schedule_version: 0, revocation_version: 0,
        attendee_index_version: 0, admission_use_reversal_version: 0,
        published_at: status.in?(%w[published cancelled]) ? @event.published_at : nil
      )
    end

    def create_payout_entry(type:, amount_minor:, available_at: @now - 30.days,
      event: @event, organization: @organization, currency: "ETB")
      Finance::LedgerEntry.create!(
        organization:,
        event:,
        type:,
        amount_minor:,
        currency:,
        available_at:,
        idempotency_key: "payout-ledger-#{SecureRandom.hex(8)}",
        description: "Payout test fact",
        created_at: available_at
      )
    end

    def build_payout(idempotency_key: "payout-build-1", amount_minor: nil,
      cutoff_at: @now)
      Finance::BuildPayout.call(
        organization: @organization,
        currency: "ETB",
        idempotency_key:,
        amount_minor:,
        cutoff_at:,
        at: @now
      )
    end

    def create_reserve_policy(provider: "chapa", currency: "ETB", target_minor: 0)
      Finance::ProviderReservePolicy.create!(provider:, currency:, target_minor:)
    end
  end
end
