# frozen_string_literal: true

module Core
  module Retention
    # Erases only due payloads, while preserving structural rows and respecting
    # legal holds. The batch is bounded so one purge run cannot monopolize locks.
    class EraseEligibleBatch < Core::BaseService
      DEFAULT_BATCH_SIZE = 100
      MAX_BATCH_SIZE = 100

      def initialize(limit: DEFAULT_BATCH_SIZE, at: Time.current)
        @limit = limit.to_i.clamp(1, MAX_BATCH_SIZE)
        @at = at
      end

      def call
        summary = { answers: 0, revisions: 0, consents: 0, skipped: 0, errors: 0, processed: 0 }
        @invalidated_event_ids = Set.new

        ActiveRecord::Base.transaction do
          lock_candidate_events!
          # Select candidates with row locks first, then hold the shared scopes
          # while rechecking and erasing each payload.
          answers = locked_answers
          remaining = @limit - answers.length
          consents = remaining.positive? ? locked_consents(remaining) : []
          lock_candidate_scopes!(answers + consents)

          answers.each { |answer| process_answer(answer, summary) }
          consents.each { |consent| process_consent(consent, summary) }
        end

        success(summary)
      end

      private

      def locked_answers
        # SKIP LOCKED lets concurrent purge workers make progress without
        # duplicating work or waiting behind a slow row.
        ids = Ticketing::RegistrationAnswer
          .joins(:retention_policy, registration_form_submission: :registration)
          .where(erased_at: nil, core_data_retention_policies: { action: "erase_payload" })
          .where("ticketing_registration_answers.retain_until <= ?", @at)
          .where(hold_exclusion_sql, @at, @at)
          .order(:retain_until, :id)
          .limit(@limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)

        Ticketing::RegistrationAnswer
          .where(id: ids)
          .includes(:retention_policy, { revisions: :registration_answer }, registration_form_submission: :registration)
          .order(:retain_until, :id)
      end

      def locked_consents(limit)
        ids = Ticketing::RegistrationConsent
          .joins(:retention_policy, :registration)
          .where(erased_at: nil, core_data_retention_policies: { action: "erase_payload" })
          .where("ticketing_registration_consents.retain_until <= ?", @at)
          .where(consent_hold_exclusion_sql, @at, @at)
          .order(:retain_until, :id)
          .limit(limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)

        Ticketing::RegistrationConsent
          .where(id: ids)
          .includes(:retention_policy, registration: [])
          .order(:retain_until, :id)
      end

      def process_answer(answer, summary)
        summary[:processed] += 1
        # A bad row rolls back to its savepoint and is counted without aborting
        # the rest of the bounded batch.
        ActiveRecord::Base.transaction(requires_new: true) do
          registration = answer.registration_form_submission.registration
          if held?(registration, answer.retention_policy.category)
            summary[:skipped] += 1
            next
          end

          invalidate_event!(registration.event_id)
          answer.update!(answer_ciphertext: nil, erased_at: @at, erasure_reason: "policy_expiry")
          answer.revisions.each do |revision|
            next if revision.erased?

            revision.update!(answer_ciphertext: nil, erased_at: @at)
            summary[:revisions] += 1
          end
          summary[:answers] += 1
        end
      rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordInvalid
        summary[:errors] += 1
      end

      def process_consent(consent, summary)
        summary[:processed] += 1
        ActiveRecord::Base.transaction(requires_new: true) do
          if held?(
            consent.registration,
            "consent_evidence",
            user_ids: [ consent.registration.user_id, consent.accepted_by_user_id ]
          )
            summary[:skipped] += 1
            next
          end

          invalidate_event!(consent.registration.event_id)
          consent.update!(
            accepted_by_user_id: nil,
            evidence_digest: nil,
            request_uuid: nil,
            idempotency_key_digest: nil,
            erased_at: @at
          )
          summary[:consents] += 1
        end
      rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordInvalid
        summary[:errors] += 1
      end

      def held?(registration, category, user_ids: [ registration.user_id ])
        # Recheck inside the write transaction because a hold may be placed after
        # the candidate query but before the payload update.
        DataRetentionHold
          .where(released_at: nil)
          .where("starts_at <= ?", @at)
          .where("expires_at IS NULL OR expires_at > ?", @at)
          .where(category: [ nil, category ])
          .where(
            "registration_id = :registration_id OR event_id = :event_id OR user_id IN (:user_ids)",
            registration_id: registration.id,
            event_id: registration.event_id,
            user_ids: user_ids.compact
          )
          .exists?
      end

      def hold_exclusion_sql
        <<~SQL.squish
          NOT EXISTS (
            SELECT 1
              FROM core_data_retention_holds retention_hold
             WHERE retention_hold.released_at IS NULL
               AND retention_hold.starts_at <= ?
               AND (retention_hold.expires_at IS NULL OR retention_hold.expires_at > ?)
               AND (retention_hold.category IS NULL OR retention_hold.category = core_data_retention_policies.category)
               AND (
                 retention_hold.registration_id = ticketing_registrations.id OR
                 retention_hold.event_id = ticketing_registrations.event_id OR
                 retention_hold.user_id = ticketing_registrations.user_id
               )
          )
        SQL
      end

      def consent_hold_exclusion_sql
        <<~SQL.squish
          NOT EXISTS (
            SELECT 1
              FROM core_data_retention_holds retention_hold
             WHERE retention_hold.released_at IS NULL
               AND retention_hold.starts_at <= ?
               AND (retention_hold.expires_at IS NULL OR retention_hold.expires_at > ?)
               AND (retention_hold.category IS NULL OR retention_hold.category = 'consent_evidence')
               AND (
                 retention_hold.registration_id = ticketing_registrations.id OR
                 retention_hold.event_id = ticketing_registrations.event_id OR
                 retention_hold.user_id = ticketing_registration_consents.accepted_by_user_id OR
                 retention_hold.user_id = ticketing_registrations.user_id
               )
          )
        SQL
      end

      def lock_candidate_scopes!(records)
        # Acquire every scope in a stable order before processing candidates to
        # prevent two purge/hold commands from deadlocking across shared scopes.
        keys = records.flat_map do |record|
           registration = record.is_a?(Ticketing::RegistrationConsent) ? record.registration :
            record.registration_form_submission.registration
          keys = {
            event: registration.event_id,
            registration: registration.id,
            user: registration.user_id
          }.compact.map { |type, id| [ "retention-scope", type, id ] }
          if record.is_a?(Ticketing::RegistrationConsent) && record.accepted_by_user_id.present?
            keys << [ "retention-scope", :user, record.accepted_by_user_id ]
          end
          keys
        end.uniq.sort_by(&:to_s)
        Core::Database::AdvisoryLock.acquire_all!(*keys)
      end

      def lock_candidate_events!
        answer_event_ids = Ticketing::RegistrationAnswer
          .joins(:retention_policy, registration_form_submission: :registration)
          .where(erased_at: nil, core_data_retention_policies: { action: "erase_payload" })
          .where("ticketing_registration_answers.retain_until <= ?", @at)
          .order(:retain_until, :id)
          .limit(@limit)
          .pluck("ticketing_registrations.event_id")
        remaining = @limit - answer_event_ids.length
        consent_event_ids = if remaining.positive?
          Ticketing::RegistrationConsent
            .joins(:retention_policy, :registration)
            .where(erased_at: nil, core_data_retention_policies: { action: "erase_payload" })
            .where("ticketing_registration_consents.retain_until <= ?", @at)
            .order(:retain_until, :id)
            .limit(remaining)
            .pluck("ticketing_registrations.event_id")
        else
          []
        end
        event_ids = (answer_event_ids + consent_event_ids).uniq.sort
        Core::Database::AdvisoryLock.acquire_all!(
          *event_ids.map { |event_id| [ "registration-privacy-event", event_id ] }
        )
      end

      def invalidate_event!(event_id)
        return if @invalidated_event_ids.include?(event_id)

        result = Ticketing::Exports::InvalidateForEvent.call(event: Events::Event.new(id: event_id))
        raise result.error if result.failure?

        @invalidated_event_ids.add(event_id)
      end
    end
  end
end
