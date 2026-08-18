# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Suspensions
    class OpenTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow
      end

      test "opens one active review case and publishes the suspended projection" do
        result = Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "suspected_fraud",
          internal_note: "Review the identity evidence before admission.",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :success?, result.error&.message
        suspension = result.value
        ticket = @ticket.reload

        assert_equal "active", suspension.status
        assert_equal @ticket.id, suspension.ticket_id
        assert_equal @event.id, suspension.event_id
        assert_equal @manager.id, suspension.initiated_by_id
        assert_equal "suspected_fraud", suspension.reason_code
        assert_equal "Review the identity evidence before admission.", suspension.internal_note
        assert_equal "active", ticket.status
        assert_equal @owner.id, ticket.owner_user_id
        assert_not ticket.revocation.is_dead
        assert ticket.revocation.is_suspended
        assert_equal 1, Ticketing::TicketSuspension.where(ticket_id: ticket.id, status: "active").count
        assert_equal 1, Core::AuditLog.where(
          auditable_type: "Ticketing::TicketSuspension",
          auditable_id: suspension.id,
          action: "ticketing.ticket_suspension.opened"
        ).count
        assert_equal 1, Core::OutboxEvent.where(
          aggregate_id: suspension.id,
          event_type: "ticketing.ticket_suspension.changed"
        ).count
      end

      test "replays the same idempotency key without a second active case" do
        key = "suspension-open-#{SecureRandom.hex(8)}"
        first = Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "identity_review",
          review_deadline_at: 3.days.from_now,
          idempotency_key: key
        )

        second = Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "identity_review",
          review_deadline_at: 3.days.from_now,
          idempotency_key: key
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal first.value.id, second.value.id
        assert_equal 1, Ticketing::TicketSuspension.where(ticket_id: @ticket.id).count
        assert_equal 1, Core::OutboxEvent.where(
          aggregate_id: first.value.id,
          event_type: "ticketing.ticket_suspension.changed"
        ).count
      end

      test "blocks a second active case with a different idempotency key" do
        first = Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        )
        second = Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "identity_review",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "suspension_already_active", second.error.code
      end

      test "blocks transfer and delegation while the package is suspended" do
        opened = Open.call(
          ticket: @ticket,
          actor: @manager,
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        )
        assert_predicate opened, :success?, opened.error&.message

        delegation = Ticketing::Delegations::Activate.call(
          ticket: @ticket,
          actor: @owner,
          assignments: { 1 => @recipient, 2 => nil, 3 => nil },
          idempotency_key: "delegation-blocked-#{SecureRandom.hex(8)}"
        )
        transfer = Ticketing::Transfers::Initiate.call(
          ticket: @ticket,
          actor: @owner,
          phone: @recipient.phone,
          idempotency_key: "transfer-blocked-#{SecureRandom.hex(8)}"
        )

        assert_predicate delegation, :failure?
        assert_equal "ticket_suspended", delegation.error.code
        assert_predicate transfer, :failure?
        assert_equal "ticket_suspended", transfer.error.code
      end

      test "exposes the shared scanner decision for a suspended package" do
        entry = JSON.parse(
          File.read(Rails.root.join("test/fixtures/files/ticketing/credential_contract_v1.json"))
        ).fetch("cases").first

        result = Ticketing::Credentials::Validator.call(
          claims: Ticketing::CredentialClaims.from_h(entry.fetch("claims")),
          **entry.fetch("context").deep_symbolize_keys,
          package_suspended: true
        )

        assert_predicate result, :success?
        assert_equal :package_suspended, result.value
      end

      test "rejects an unauthorized opener" do
        result = Open.call(
          ticket: @ticket,
          actor: @owner,
          reason_code: "suspected_fraud",
          review_deadline_at: 3.days.from_now,
          idempotency_key: "suspension-open-#{SecureRandom.hex(8)}"
        )

        assert_predicate result, :failure?
        assert_equal "suspension_forbidden", result.error.code
      end
    end
  end
end
