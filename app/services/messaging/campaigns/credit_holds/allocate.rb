# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Allocates one delivery slice without reserving against the wallet again.
      # Fan-out uses AllocateBatch; this one-row primitive remains the tested
      # command for isolated callers and allocation identity verification.
      class Allocate < Core::BaseService
        include AllocationIdentity

        def initialize(reservation:, delivery:, quantity:, idempotency_key:)
          @reservation = reservation
          @delivery = delivery
          @quantity = quantity
          @key = Core::IdempotencyKey.new(idempotency_key)
        end

        def call
          return failure(error(:invalid_credit_quantity)) unless @quantity.is_a?(Integer) && @quantity.positive?
          return failure(error(:credit_hold_invalid)) unless valid_scope?

          ActiveRecord::Base.transaction do
            hold = CreditReservation.lock.find(@reservation.id)
            existing = CampaignCreditAllocation.lock.find_by(delivery_id: @delivery.id)
            return replay(existing) if existing
            return failure(error(:credit_hold_exhausted, status: :conflict)) if allocated(hold) + @quantity > hold.quantity

            allocation = CampaignCreditAllocation.create!(
              campaign_id: @delivery.campaign_id,
              delivery: @delivery,
              credit_reservation: hold,
              quantity: @quantity,
              status: "allocated",
              idempotency_key_digest: AllocationIdentity.digest(
                reservation: hold, delivery: @delivery, quantity: @quantity
              )
            )
            success(allocation)
          end
        rescue ActiveRecord::RecordNotUnique
          replay(CampaignCreditAllocation.find_by!(delivery_id: @delivery.id))
        rescue ArgumentError => exception
          failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:credit_hold_invalid, message: exception.message))
        end

        private

        def valid_scope?
          @reservation.is_a?(CreditReservation) && @delivery.is_a?(CampaignDelivery) &&
            @reservation.status == "reserved" &&
            @reservation.source_type == "Messaging::Campaign" &&
            @reservation.source_id == @delivery.campaign_id
        end

        def allocated(hold)
          hold.allocations.sum(:quantity)
        end

        def replay(existing)
          return failure(error(:credit_idempotency_conflict, status: :conflict)) unless existing
          return success(existing) if existing.credit_reservation_id == @reservation.id &&
            existing.delivery_id == @delivery.id && existing.quantity == @quantity

          failure(error(:credit_idempotency_conflict, status: :conflict))
        end

        def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
