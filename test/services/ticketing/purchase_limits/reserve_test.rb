# frozen_string_literal: true

require "test_helper"

module Ticketing
  module PurchaseLimits
    class ReserveTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers

      setup do
        setup_consent_context
        @ticket_type.update!(max_packages_per_user: 2)
      end

      test "reserves one allocation per package unit" do
        result = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 2,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-package-units"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal [ 1, 2 ], result.value.map(&:unit_number)
        assert_equal %w[reserved reserved], result.value.map(&:status)
        assert_equal [ @actor.id ], result.value.map(&:user_id).uniq
        assert_equal [ @ticket_type.id ], result.value.map(&:ticket_type_id).uniq
      end

      test "reserves a gift-pending registration against the recipient rather than the purchaser" do
        recipient = core_users(:support)
        registration = create_registration(status: "gift_pending_claim", user: recipient)

        result = Reserve.call(
          registration:,
          user: recipient,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-recipient-gift"
        )
        payer_attempt = Reserve.call(
          registration:,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-gift-as-payer"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal [ recipient.id ], result.value.map(&:user_id).uniq
        assert_predicate payer_attempt, :failure?
        assert_equal "purchase_limit_user_mismatch", payer_attempt.error.code
      end

      test "rejects a reservation when reserved and committed units reach the limit" do
        first = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 2,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-at-limit"
        )
        assert_predicate first, :success?, first.error&.message

        other_registration = create_registration(status: "cancelled")
        result = Reserve.call(
          registration: other_registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-over-limit"
        )

        assert_predicate result, :failure?
        assert_equal "purchase_limit_exceeded", result.error.code
        assert_equal 2, PurchaseLimitAllocation.where(user: @actor, status: %w[reserved committed]).count
      end

      test "enforces the cumulative cap across separate registrations" do
        first = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-repeat-first"
        )
        assert_predicate first, :success?, first.error&.message
        committed = Commit.call(
          registration: @registration,
          user: @actor,
          idempotency_key: "commit-repeat-first"
        )
        assert_predicate committed, :success?, committed.error&.message

        second_registration = create_registration(status: "cancelled")
        second = Reserve.call(
          registration: second_registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-repeat-second"
        )
        assert_predicate second, :success?, second.error&.message

        third_registration = create_registration(status: "cancelled")
        third = Reserve.call(
          registration: third_registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-repeat-third"
        )

        assert_predicate third, :failure?
        assert_equal "purchase_limit_exceeded", third.error.code
      end

      test "releases expired reservations before counting availability" do
        expired_registration = create_registration(status: "cancelled")
        PurchaseLimitAllocation.create!(
          ticket_type: @ticket_type,
          user: @actor,
          registration: expired_registration,
          unit_number: 1,
          status: "reserved",
          expires_at: 1.minute.ago,
          idempotency_key: "expired-reservation"
        )

        result = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 2,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-after-expiry"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "released", PurchaseLimitAllocation.find_by!(idempotency_key: "expired-reservation").status
        assert_equal "expired", PurchaseLimitAllocation.find_by!(idempotency_key: "expired-reservation").release_reason
        assert_equal 2, PurchaseLimitAllocation.where(status: "reserved", registration: @registration).count
      end

      test "uses the selected event date as the purchase-limit scope for choose-one tickets" do
        @ticket_type.update!(date_selection: "choose_one", max_packages_per_user: 1)
        first_date = @event.event_dates.create!(
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 1.hour,
          status: "scheduled"
        )
        second_date = @event.event_dates.create!(
          starts_at: 2.days.from_now,
          ends_at: 2.days.from_now + 1.hour,
          status: "scheduled"
        )
        [ first_date, second_date ].each do |event_date|
          Catalog::ProductAccess.create!(event_product: @ticket_type.event_product, event_date:, type: "venue")
        end
        @registration.update!(selected_event_date: first_date)
        other_registration = create_registration(status: "cancelled", selected_event_date: second_date)

        first = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-first-date"
        )
        second = Reserve.call(
          registration: other_registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-second-date"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        assert_equal first_date.id, first.value.first.scope_event_date_id
        assert_equal second_date.id, second.value.first.scope_event_date_id
      end

      test "replaying the same reservation key does not create duplicate allocations" do
        subject = lambda do
          Reserve.call(
            registration: @registration,
            user: @actor,
            quantity: 2,
            expires_at: 10.minutes.from_now,
            idempotency_key: "reserve-replay"
          )
        end

        assert_idempotent(subject, counter: -> { PurchaseLimitAllocation.count })
      end

      test "reusing a reservation key with a different quantity returns a conflict" do
        first = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 1,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-quantity-conflict"
        )
        second = Reserve.call(
          registration: @registration,
          user: @actor,
          quantity: 2,
          expires_at: 10.minutes.from_now,
          idempotency_key: "reserve-quantity-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "purchase_limit_idempotency_conflict", second.error.code
        assert_equal 1, PurchaseLimitAllocation.where(registration: @registration).count
      end

      private

      def create_registration(status:, selected_event_date: nil, user: @actor)
        Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user:,
          created_by: user,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: @ticket_type.admissions_per_unit,
          party_size: @ticket_type.admissions_per_unit,
          selected_event_date:,
          status:,
          submitted_at: Time.current
        )
      end
    end

    class ReserveConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:attendee)
        @ticket_type = create_ticket_type
        @first_registration = create_registration
        @second_registration = create_registration
      end

      teardown do
        PurchaseLimitAllocation.where(registration_id: [ @first_registration.id, @second_registration.id ]).delete_all
        Ticketing::Registration.where(id: [ @first_registration.id, @second_registration.id ]).delete_all
        Ticketing::TicketType.where(id: @ticket_type.id).delete_all
        Catalog::EventProduct.where(id: @ticket_type.event_product_id).delete_all
      end

      test "serializes concurrent reservations for the final allowed package" do
        ready = Queue.new
        start = Queue.new
        results = [ @first_registration, @second_registration ].map do |registration|
          Thread.new do
            Ticketing::ApplicationRecord.connection_pool.with_connection do
              ready << true
              start.pop
              PurchaseLimits::Reserve.call(
                registration: Ticketing::Registration.find(registration.id),
                user: Core::User.find(@actor.id),
                quantity: 1,
                expires_at: 10.minutes.from_now,
                idempotency_key: "concurrent-#{registration.id}"
              )
            end
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        results = results.map(&:value)

        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count(&:failure?)
        assert_equal "purchase_limit_exceeded", results.find(&:failure?).error.code
      end

      private

      def create_ticket_type
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Limited ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1, max_packages_per_user: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
      end

      def create_registration
        Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @actor,
          created_by: @actor,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "cancelled",
          submitted_at: Time.current
        )
      end
    end
  end
end
