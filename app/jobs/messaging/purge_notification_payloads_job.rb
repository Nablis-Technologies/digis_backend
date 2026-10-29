# frozen_string_literal: true

module Messaging
  # Erases expired notification payloads while retaining the inbox row and its
  # delivery identity. Bounded row locks and hold rechecks keep maintenance
  # work safe to retry without deleting evidence needed for reconciliation.
  class PurgeNotificationPayloadsJob < ApplicationJob
    queue_as :notifications

    BATCH_SIZE = 100

    def perform(limit = BATCH_SIZE)
      at = Time.current
      summary = { processed: 0, erased: 0, skipped: 0, errors: 0 }
      ids = candidate_ids(limit, at)
      @retention_scopes = RetentionScopeResolver.call(notification_ids: ids)
      ids.each do |notification_id|
        summary[:processed] += 1
        process(notification_id, at, summary)
      end
      Rails.logger.info("Messaging notification purge completed: #{summary.inspect}")
      summary
    ensure
      @retention_scopes = nil
    end

    private

    def candidate_ids(limit, at)
      Notification
        .joins(:retention_policy)
        .where(erased_at: nil, core_data_retention_policies: { action: "erase_payload" })
        .where("messaging_notifications.retain_until <= ?", at)
        .order(:retain_until, :id)
        .limit(limit.to_i.clamp(1, BATCH_SIZE))
        .lock("FOR UPDATE SKIP LOCKED")
        .pluck(:id)
    end

    def process(notification_id, at, summary)
      Notification.transaction(requires_new: true) do
        notification = Notification.lock.find_by(id: notification_id)
        next unless notification&.retain_until && notification.erased_at.nil? && notification.retain_until <= at

        scope = @retention_scopes.fetch(notification.id) { retention_scope_for(notification) }
        lock_scope!(scope)
        if held?(scope, at)
          summary[:skipped] += 1
          next
        end

        # The normal model validation requires a future retain_until for a
        # live payload; this maintenance transition intentionally crosses that
        # deadline, so the candidate query is the validation boundary here.
        notification.update_columns(data: {}, erased_at: at, erasure_reason: "policy_expiry", updated_at: at)
        summary[:erased] += 1
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid
      summary[:errors] += 1
    end

    def held?(scope, at)
      Core::DataRetentionHold
        .where(category: [ nil, "messaging_notification" ])
        .where("starts_at <= ?", at)
        .where("expires_at IS NULL OR expires_at > ?", at)
        .where(
          "user_id IN (:user_ids) OR event_id IN (:event_ids) OR registration_id IN (:registration_ids)",
          user_ids: scope.fetch(:user_ids),
          event_ids: scope.fetch(:event_ids).presence || [ nil ],
          registration_ids: scope.fetch(:registration_ids).presence || [ nil ]
        )
        .exists?
    end

    def retention_scope_for(notification)
      RetentionScopeResolver.call(notification_ids: [ notification.id ]).fetch(notification.id)
    end

    def lock_scope!(scope)
      # Hold placement uses the same ordered advisory keys; taking them before
      # the final hold query closes the race between a hold and payload erase.
      keys = scope.fetch(:event_ids).compact.map { |id| [ "retention-scope", :event, id ] } +
        scope.fetch(:registration_ids).compact.map { |id| [ "retention-scope", :registration, id ] } +
        scope.fetch(:user_ids).compact.map { |id| [ "retention-scope", :user, id ] }
      Core::Database::AdvisoryLock.acquire_all!(*keys.uniq.sort_by(&:to_s))

      nil
    end
  end
end
