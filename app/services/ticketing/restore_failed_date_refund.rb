# frozen_string_literal: true

module Ticketing
  # Restores a date after a provider failure by creating a newer credential
  # generation. The failed refund item remains immutable evidence and the prior
  # generation is never reactivated.
  class RestoreFailedDateRefund < Core::BaseService
    def initialize(refund:)
      @refund = refund
    end

    def call
      refund, item = load_refund
      return failure(date_error(:date_refund_invalid)) unless failed_date_refund?(refund, item)

      ticket = load_ticket(item.ticket_id)
      generation = Ticketing::CredentialGeneration.includes(
        credentials: [ :admission_slot, :holder_user ]
      ).lock.find(ticket.current_credential_generation_id)
      excluded_date_ids = Array(generation.excluded_event_date_ids).map(&:to_s)
      return success(generation) unless excluded_date_ids.include?(item.event_date_id.to_s)

      excluded = excluded_date_ids - [ item.event_date_id.to_s ]
      replacement = Ticketing::CredentialGenerations::Replace.call(
        ticket:,
        target_mode: generation.mode,
        reason: "date_refund_failed_restore",
        assignments: assignments_for(generation),
        excluded_event_date_ids: excluded,
        allow_suspended: true,
        idempotency_key: "ticketing-date-refund-restore-#{refund.id}"
      )
      return failure(replacement.error) if replacement.failure?

      success(replacement.value)
    rescue ActiveRecord::RecordNotFound
      failure(date_error(:date_refund_not_found, :not_found))
    end

    private

    def load_refund
      refund = Orders::Refund.includes(refund_items: [ :ticket, :event_date ]).lock.find(@refund.id)
      [ refund, refund.refund_items.one? ? refund.refund_items.first : nil ]
    end

    def load_ticket(ticket_id)
      Ticketing::Ticket.includes(
        :event,
        :revocation,
        admission_slots: :assigned_user,
        event_product: [ :ticket_type, { product_accesses: :event_date } ]
      ).lock.find(ticket_id)
    end

    def failed_date_refund?(refund, item)
      refund && item && refund.type == "item_refund" && refund.status == "failed" &&
        item.ticket_id.present? && item.event_date_id.present?
    end

    def assignments_for(generation)
      return {} if generation.mode == "group"

      generation.credentials.each_with_object({}) do |credential, assignments|
        assignments[credential.admission_slot.position] = credential.holder_user
      end
    end

    def date_error(key, status = :unprocessable_entity)
      Core::BusinessError.new(
        I18n.t("ticketing.suspensions.errors.#{key}"), code: key, status:
      )
    end
  end
end
