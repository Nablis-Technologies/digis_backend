# frozen_string_literal: true

module Ticketing
  # Removes one event date from a package by replacing its active credential
  # generation before provider submission. The generation snapshots the sparse
  # date exclusion so stale QR/PNR and attendee-index rows cannot grant access.
  class ApplyDateRefund < Core::BaseService
    def initialize(refund:)
      @refund = refund
    end

    def call
      refund, item = load_refund
      return failure(date_error(:date_refund_invalid)) unless valid_refund?(refund, item)

      ticket = load_ticket(item.ticket_id)
      return failure(date_error(:date_refund_invalid)) unless date_granted_by_product?(ticket, item)
      return failure(date_error(:date_refund_date_used, :conflict)) if date_used?(ticket, item)
      generation = Ticketing::CredentialGeneration.includes(
        credentials: [ :admission_slot, :holder_user ]
      ).lock.find(ticket.current_credential_generation_id)
      return failure(date_error(:generation_not_active, :conflict)) unless generation.status == "active"

      excluded = (Array(generation.excluded_event_date_ids) + [ item.event_date_id.to_s ]).map(&:to_s).uniq.sort
      return failure(date_error(:date_refund_no_remaining_access, :conflict)) unless remaining_access?(ticket, excluded)

      replacement = Ticketing::CredentialGenerations::Replace.call(
        ticket:,
        target_mode: generation.mode,
        reason: "date_refund_processing",
        assignments: assignments_for(generation),
        excluded_event_date_ids: excluded,
        idempotency_key: "ticketing-date-refund-apply-#{refund.id}"
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

    def valid_refund?(refund, item)
      return false unless refund && item

      refund.type == "item_refund" &&
        refund.status.in?(%w[created pending_funds processing succeeded]) &&
        item.ticket_id.present? && item.event_date_id.present?
    end

    def date_used?(ticket, item)
      Ticketing::AdmissionUse.joins(:admission_slot).where(
        ticketing_admission_slots: { ticket_id: item.ticket_id },
        product_access_id: ticket.event_product.product_accesses
          .select { |access| access.event_date_id == item.event_date_id }
          .map(&:id)
      ).exists?
    end

    def date_granted_by_product?(ticket, item)
      ticket.event_product.product_accesses.any? { |access| access.event_date_id == item.event_date_id }
    end

    def remaining_access?(ticket, excluded)
      ticket.event_product.product_accesses.any? do |access|
        !excluded.include?(access.event_date_id.to_s)
      end
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
