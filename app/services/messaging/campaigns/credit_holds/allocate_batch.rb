# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Allocates a claimed recipient page while locking the aggregate once.
      class AllocateBatch < Core::BaseService
        def initialize(reservation:, deliveries:)
          @reservation = reservation
          @deliveries = Array(deliveries)
        end

        def call
          return failure(error(:credit_hold_invalid)) unless valid_request?

          ActiveRecord::Base.transaction do
            hold = CreditReservation.lock.find(@reservation.id)
            return failure(error(:credit_hold_invalid)) unless hold.status == "reserved"

            existing = CampaignCreditAllocation.where(delivery_id: @deliveries.map(&:id)).index_by(&:delivery_id)
            pending = @deliveries.uniq { |delivery| delivery.id }.reject { |delivery| existing.key?(delivery.id) }
            return success(true) if pending.empty?

            quantity = pending.sum { |delivery| delivery.campaign_recipient.quantity }
            return failure(error(:credit_hold_exhausted, status: :conflict)) if hold.allocations.sum(:quantity) + quantity > hold.quantity

            CampaignCreditAllocation.insert_all(pending.map do |delivery|
              now = Time.current
              {
                campaign_id: delivery.campaign_id,
                delivery_id: delivery.id,
                credit_reservation_id: hold.id,
                quantity: delivery.campaign_recipient.quantity,
                status: "allocated",
                idempotency_key_digest: AllocationIdentity.digest(
                  reservation: hold, delivery:, quantity: delivery.campaign_recipient.quantity
                ),
                created_at: now,
                updated_at: now
              }
            end, unique_by: :idx_messaging_campaign_credit_allocations_delivery)
          end
          success(true)
        rescue ActiveRecord::RecordInvalid => exception
          failure(error(:credit_hold_invalid, message: exception.message))
        end

        private

        def valid_request?
          @reservation.is_a?(CreditReservation) && @deliveries.all? do |delivery|
            delivery.is_a?(CampaignDelivery) && delivery.campaign_id == @reservation.source_id
          end
        end

        def error(key, message: nil, status: :unprocessable_entity)
          Core::BusinessError.new(message || I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
        end
      end
    end
  end
end
