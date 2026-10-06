# frozen_string_literal: true

module Orders
  class ExpireGiftPurchasesJob < ApplicationJob
    queue_as :default

    # Expire one independently locked gift per job, then chain a bounded cursor
    # drain. This avoids a long event-wide transaction and per-row service
    # queries inside one oversized batch.
    BATCH_SIZE = 1

    def perform(cursor: nil, limit: BATCH_SIZE, now: Time.current)
      batch_size = [ limit.to_i, BATCH_SIZE ].min.clamp(1, BATCH_SIZE)
      scope = GiftPurchase.due_for_expiry(now).order(:id)
      scope = scope.where("id > ?", cursor) if cursor.present?
      gifts = scope.limit(batch_size).to_a

      gifts.each do |gift|
        result = GiftPurchases::Expire.call(gift_purchase: gift, at: now)
        raise result.error if result.failure?
      end

      self.class.perform_later(cursor: gifts.last.id, limit: batch_size, now:) if gifts.size == batch_size
    end
  end
end
