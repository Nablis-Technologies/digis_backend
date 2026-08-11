# frozen_string_literal: true

require "test_helper"

module Commercial
  class SubsidyReservationTest < ActiveSupport::TestCase
    include Commercial::SubsidyReservationTestHelpers

    setup do
      setup_subsidy_reservation_context
    end

    test "accepts a held reservation with matching order and budget currency" do
      reservation = build_reservation

      assert_predicate reservation, :valid?
      assert reservation.active?
      assert reservation.held?
      assert_equal 500, reservation.amount_minor
    end

    test "requires state-coupled timestamps" do
      held_without_expiry = build_reservation(expires_at: nil)
      processing_with_commit = build_reservation(status: "processing", committed_at: Time.current)
      committed_without_commit_time = build_reservation(status: "committed")
      released_without_release_time = build_reservation(status: "released")
      released_with_commit_time = build_reservation(status: "released", released_at: Time.current,
        committed_at: Time.current)

      assert_not held_without_expiry.valid?
      assert_not processing_with_commit.valid?
      assert_not committed_without_commit_time.valid?
      assert_not released_without_release_time.valid?
      assert_not released_with_commit_time.valid?
    end

    test "requires positive amounts, matching currency, and SHA-256 evidence" do
      invalid = build_reservation(
        amount_minor: 0,
        currency: "USD",
        idempotency_key_digest: "a" * 63,
        request_fingerprint: "not-a-digest"
      )

      assert_not invalid.valid?
      assert invalid.errors.key?(:amount_minor)
      assert invalid.errors.key?(:currency)
      assert invalid.errors.key?(:idempotency_key_digest)
      assert invalid.errors.key?(:request_fingerprint)
    end

    test "does not allow a reservation to cross order or budget currency boundaries" do
      invalid_order = build_reservation(currency: "USD")
      invalid_budget = build_reservation(currency: "USD")
      invalid_budget.subsidy_budget = Commercial::SubsidyBudget.new(
        assignment: @assignment,
        fee_component: @component,
        currency: "USD",
        limit_minor: 1_000
      )

      assert_not invalid_order.valid?
      assert_not invalid_budget.valid?
      assert invalid_order.errors.key?(:currency)
      assert invalid_budget.errors.key?(:currency)
    end

    test "exposes safe query contracts and associations" do
      assert_equal "Commercial::SubsidyBudget",
        SubsidyReservation.reflect_on_association(:subsidy_budget).class_name
      assert_equal "Orders::Order", SubsidyReservation.reflect_on_association(:order).class_name
      assert_includes SubsidyReservation.ransackable_attributes, "request_fingerprint"
      assert_includes SubsidyReservation.ransackable_associations, "order"
    end

    test "validates persisted reservations without lazy-loading associations" do
      reservation = build_reservation
      reservation.save!
      fetched = SubsidyReservation.strict_loading.find(reservation.id)

      assert_predicate fetched, :valid?
    end

    test "does not permit reservation history to be destroyed through the model" do
      reservation = build_reservation
      reservation.save!

      assert_raises(ActiveRecord::ReadOnlyRecord) { reservation.destroy! }
    end

    test "does not permit reservation snapshots or terminal states to change" do
      reservation = build_reservation
      reservation.save!
      reservation.amount_minor = 600

      assert_not reservation.valid?
      assert reservation.errors.key?(:amount_minor)

      reservation.reload
      reservation.update!(status: "released", released_at: Time.current)
      reservation.status = "held"

      assert_not reservation.valid?
      assert reservation.errors.key?(:status)
    end

    test "database enforces reservation invariants" do
      assert_database_rejects(amount_minor: 0)
      assert_database_rejects(currency: "usd")
      assert_database_rejects(idempotency_key_digest: "a" * 63)
      assert_database_rejects(request_fingerprint: "b" * 63)
      assert_database_rejects(status: "held", expires_at: nil)
      assert_database_rejects(status: "committed", committed_at: nil)
      assert_database_rejects(status: "released", released_at: nil)
      assert_database_rejects(subsidy_budget_id: SecureRandom.uuid)
      assert_database_rejects(order_id: SecureRandom.uuid)
      reservation = assert_database_update_rejects(amount_minor: 600)
      assert_database_terminal_delete_rejects(reservation)
    end

    private

    def assert_database_rejects(attributes)
      database_attributes = {
        subsidy_budget_id: @budget.id,
        order_id: @order.id,
        idempotency_key_digest: "a" * 64,
        request_fingerprint: "b" * 64,
        amount_minor: 500,
        currency: "ETB",
        status: "held",
        expires_at: 10.minutes.from_now,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(attributes)

      assert_raises(ActiveRecord::StatementInvalid) do
        SubsidyReservation.transaction(requires_new: true) do
          SubsidyReservation.insert_all!([ database_attributes.merge(id: SecureRandom.uuid) ])
        end
      end
    end

    def assert_database_update_rejects(attributes)
      reservation = build_reservation
      reservation.save!

      assert_raises(ActiveRecord::StatementInvalid) do
        SubsidyReservation.transaction(requires_new: true) do
          SubsidyReservation.where(id: reservation.id).update_all(attributes)
        end
      end

      reservation
    end

    def assert_database_terminal_delete_rejects(reservation)
      reservation.update_columns(status: "released", released_at: Time.current)

      assert_raises(ActiveRecord::StatementInvalid) do
        SubsidyReservation.transaction(requires_new: true) do
          SubsidyReservation.where(id: reservation.id).delete_all
        end
      end
    end
  end
end
