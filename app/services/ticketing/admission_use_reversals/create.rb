# frozen_string_literal: true

module Ticketing
  module AdmissionUseReversals
    # Appends one complete reversal group for a successful group check-in.
    # The check-in, ticket, use, access, and slot locks follow the documented
    # reversal order so a correction cannot race a new admission or produce a
    # partial group.
    class Create < Core::BaseService
      def initialize(checkin_log:, manager:, reason_code:, idempotency_key:, note: nil, now: Time.current)
        @checkin_log = checkin_log
        @manager = manager
        @reason_code = reason_code.to_s.strip
        @idempotency_key = idempotency_key
        @note = note.to_s.strip.presence
        @now = now
      end

      def call
        Core::IdempotencyKey.new(@idempotency_key)
        return failure(error(:admission_use_reversal_invalid, :unprocessable_entity)) if @reason_code.blank?

        checkin = Ticketing::CheckinLog.find(@checkin_log.id)
        event_id = Ticketing::Ticket.where(id: checkin.ticket_id).pick(:event_id)
        event = Events::Event.find(event_id)
        return failure(error(:admission_use_reversal_forbidden, :forbidden)) unless
          Events::AuthorizationResolver.can_manage_catalog?(@manager, event)

        outcome = nil
        Ticketing::ApplicationRecord.transaction do
          locked_checkin = Ticketing::CheckinLog.lock.find(checkin.id)
          ticket = Ticketing::Ticket.lock.find(checkin.ticket_id)
          uses = Ticketing::AdmissionUse.where(checkin_log_id: locked_checkin.id)
            .order(:admission_slot_id, :id).lock.to_a
          product_access = Catalog::ProductAccess.lock.find(locked_checkin.product_access_id)
          slots = Ticketing::AdmissionSlot.where(ticket_id: ticket.id, id: uses.map(&:admission_slot_id))
            .order(:position, :id).lock.to_a

          existing = Ticketing::AdmissionUseReversal.where(admission_use_id: uses.map(&:id))
            .order(:id).to_a
          if existing.any?
            outcome = replay_or_conflict(existing, locked_checkin)
            next
          end

          invalid = invalid_checkin(locked_checkin, uses, product_access, slots)
          if invalid
            outcome = failure(invalid)
            next
          end

          event.lock!
          reversal_version = event.admission_use_reversal_version.to_i + 1
          event.update!(admission_use_reversal_version: reversal_version)
          group_id = reversal_group_id(locked_checkin)
          reversals = uses.map do |use|
            Ticketing::AdmissionUseReversal.create!(
              event:,
              admission_use: use,
              checkin_log: locked_checkin,
              reversal_group_id: group_id,
              reversed_by: @manager,
              reason_code: @reason_code,
              note: @note,
              reversal_version:,
              reversed_at: @now
            )
          end

          record_audit!(reversals, locked_checkin, event, reversal_version)
          publish_outbox!(reversals, locked_checkin, event, reversal_version)
          outcome = success(
            reversal_group_id: group_id,
            reversals:,
            checkin_log_id: locked_checkin.id,
            event_id: event.id,
            reversal_version:
          )
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:admission_use_reversal_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(
          error(
            :admission_use_reversal_invalid,
            :unprocessable_entity,
            errors: exception.record.errors.to_hash
          )
        )
      rescue ArgumentError
        failure(error(:admission_use_reversal_invalid, :unprocessable_entity))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def invalid_checkin(checkin, uses, product_access, slots)
        return error(:admission_use_reversal_not_possible, :conflict) unless checkin.result == "success"
        return error(:admission_use_reversal_not_possible, :conflict) if uses.empty? || slots.empty?
        return error(:admission_use_reversal_not_possible, :conflict) unless
          uses.all? { |use| use.product_access_id == product_access.id }

        nil
      end

      def replay_or_conflict(existing, checkin)
        group_ids = existing.map(&:reversal_group_id).uniq
        return failure(error(:admission_use_reversal_invalid, :conflict)) unless group_ids.one?

        group_id = group_ids.first
        if group_id == reversal_group_id(checkin)
          return success(reversal_result(existing, checkin, group_id)) if
            existing.all? do |reversal|
              reversal.reversed_by_id == @manager.id &&
                reversal.reason_code == @reason_code && reversal.note == @note
            end

          return failure(error(:idempotency_conflict, :conflict))
        end

        if existing.all? do |reversal|
          reversal.reversed_by_id == @manager.id &&
            reversal.reason_code == @reason_code && reversal.note == @note
        end
          failure(error(:admission_use_reversal_already_exists, :conflict))
        else
          failure(error(:idempotency_conflict, :conflict))
        end
      end

      def reversal_result(reversals, checkin, group_id)
        {
          reversal_group_id: group_id,
          reversals:,
          checkin_log_id: checkin.id,
          event_id: reversals.first.event_id,
          reversal_version: reversals.first.reversal_version
        }
      end

      def reversal_group_id(checkin)
        Ticketing::IdempotencyUuid.from(
          @idempotency_key,
          namespace: "ticketing-admission-use-reversal:#{checkin.id}"
        )
      end

      def record_audit!(reversals, checkin, event, reversal_version)
        Core::Audit::Record.call(
          audit_key: "ticketing-admission-use-reversal-#{reversals.first.reversal_group_id}",
          action: "ticketing.admission_use.reversal_recorded",
          auditable_type: Ticketing::AdmissionUseReversal.name,
          auditable_id: reversals.first.id,
          actor_type: @manager.class.name,
          actor_id: @manager.id,
          audited_changes: { reversal_version: [ reversal_version - 1, reversal_version ] },
          metadata: {
            event_id: event.id,
            checkin_log_id: checkin.id,
            reversal_group_id: reversals.first.reversal_group_id,
            admission_use_count: reversals.length
          }
        )
      end

      def publish_outbox!(reversals, checkin, event, reversal_version)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.admission_use.reversal_recorded",
          aggregate: event,
          payload: {
            event_id: event.id,
            checkin_log_id: checkin.id,
            reversal_group_id: reversals.first.reversal_group_id,
            admission_use_ids: reversals.map(&:admission_use_id),
            reversal_version:
          },
          idempotency_key: "ticketing-admission-use-reversal-#{reversals.first.reversal_group_id}"
        )
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key,
          status:,
          errors:
        )
      end
    end
  end
end
