  # frozen_string_literal: true

  module Ticketing
    module Registrations
      # Shared capacity primitives. Every reservation, commit, and release keeps
      # purchase-limit rows and inventory rows in the same transaction boundary.
      module Support
      class Halt < StandardError
        attr_reader :result

        def initialize(result)
          @result = result
          super(result.error.message)
        end
      end

      private

      def reserve_capacity!(registration, idempotency_key:, expires_at: 10.minutes.from_now,
        reservation_group_id: registration.id)
        # Roll back purchase-limit rows if inventory rejects the same request.
        ActiveRecord::Base.transaction do
          purchase_limit = Ticketing::PurchaseLimits::Reserve.call(
            registration:,
            user: registration.user,
            quantity: registration.package_quantity,
            expires_at:,
            idempotency_key: "#{idempotency_key}:purchase-limit"
          )
          unwrap(purchase_limit)

          unwrap(Catalog::Inventory::Reserve.call(
            product: registration.ticket_type.event_product,
            event_date_ids: registration.ticket_type.covered_date_ids(registration),
            package_quantity: registration.package_quantity,
            admissions_per_unit: registration.admissions_per_unit_snapshot,
            owner: registration,
            reservation_group_id:,
            expires_at:
          ))
        end
        Core::BaseService::Result.success(registration)
      rescue Support::Halt => error
        error.result
      end

      def commit_capacity!(registration, idempotency_key:)
        # A registration may have multiple historical offer groups; commit only
        # groups that still have active holds and leave released history intact.
        group_ids = Catalog::InventoryReservation
          .where(registration_id: registration.id, status: %w[held processing])
          .distinct
          .pluck(:reservation_group_id)
        group_ids.concat(
          Catalog::VenueCapacityReservation
            .where(registration_id: registration.id, status: %w[held processing])
            .distinct
            .pluck(:reservation_group_id)
        )
        group_ids.uniq.each do |group_id|
          inventory = Catalog::Inventory::Commit.call(reservation_group_id: group_id)
          return inventory if inventory.failure?
        end

        return Core::BaseService::Result.success([]) unless
          Ticketing::PurchaseLimitAllocation
            .where(registration_id: registration.id, status: %w[reserved committed])
            .exists?

        Ticketing::PurchaseLimits::Commit.call(
          registration:,
          user: registration.user,
          idempotency_key: "#{idempotency_key}:purchase-limit"
        )
      end

      def release_capacity!(registration, idempotency_key:, reason: "expired")
        # Release every active offer group before releasing its purchase-limit
        # allocation, preserving both histories for later reconciliation.
        group_ids = Catalog::InventoryReservation
          .where(registration_id: registration.id, status: %w[held processing])
          .distinct
          .pluck(:reservation_group_id)
        group_ids.concat(
          Catalog::VenueCapacityReservation
            .where(registration_id: registration.id, status: %w[held processing])
            .distinct
            .pluck(:reservation_group_id)
        )
        group_ids.uniq.each do |group_id|
          inventory = Catalog::Inventory::Release.call(reservation_group_id: group_id)
          return inventory if inventory.failure?
        end

        return Core::BaseService::Result.success([]) unless
          Ticketing::PurchaseLimitAllocation
            .where(registration_id: registration.id, status: %w[reserved committed])
            .exists?

        Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: registration.user,
          reason:,
          idempotency_key: "#{idempotency_key}:purchase-limit"
        )
      end

      def required_buyer_consents_complete?(registration)
        !registration.consent_requirements
          .where(acceptance_scope: "buyer", required: true)
          .where.not(status: "accepted")
          .exists?
      end

      def free_product?(registration)
        registration.ticket_type.event_product.free?
      end

      def workflow_error(code)
        Core::BusinessError.new(
          I18n.t("ticketing.registration_workflows.errors.#{code}"),
          code:,
          status: :unprocessable_entity
        )
      end

      def unwrap(result)
        return result.value if result.success?

        fail Support::Halt, result
      end
      end
    end
  end
