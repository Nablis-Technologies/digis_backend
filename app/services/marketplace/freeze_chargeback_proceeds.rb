# frozen_string_literal: true

module Marketplace
  # Appends a seller-side chargeback fact for one accepted resale payment. A
  # chargeback on the current acquisition opens the existing temporary package
  # suspension; a historical-chain chargeback records seller risk without
  # revoking the valid current holder's credential.
  class FreezeChargebackProceeds < Core::BaseService
    class Abort < Core::Error
      attr_reader :business_error

      def initialize(business_error)
        @business_error = business_error
        super(business_error.message)
      end
    end

    def initialize(payment:, actor:, amount_minor: nil, idempotency_key: nil, at: Time.current)
      @payment_id = payment.id
      @actor = actor
      @amount_minor = amount_minor
      @raw_idempotency_key = idempotency_key
      @at = at.to_time.utc
    rescue NoMethodError, ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(chargeback_error(:invalid_idempotency_key)) if @initialization_error

      outcome = ActiveRecord::Base.transaction do
        payment, sale, ticket, _event = lock_context
        amount = validate_amount!(sale)
        key = chargeback_key(sale, amount)
        existing = SellerLedgerEntry.lock.find_by(idempotency_key: key)
        if existing
          ensure_current_suspension!(ticket, sale)
          next success(existing)
        end

        existing_amount = SellerLedgerEntry.where(
          resale_sale_id: sale.id, type: "chargeback"
        ).lock.to_a.sum { |entry| entry.amount_minor.abs }
        abort_with(:chargeback_amount_exceeded) if existing_amount + amount > sale.gross_amount_minor

        proceeds = SellerLedgerEntry.lock.find_by(
          resale_sale_id: sale.id, type: "resale_proceeds"
        )
        abort_with(:chargeback_proceeds_missing) unless proceeds

        entry = SellerLedgerEntry.create!(
          seller_user: sale.seller_user,
          event: sale.event,
          resale_sale: sale,
          reverses_entry: amount == proceeds.amount_minor ? proceeds : nil,
          type: "chargeback",
          amount_minor: -amount,
          currency: sale.currency,
          available_at: at,
          idempotency_key: key,
          description: I18n.t("marketplace.resale.ledger_descriptions.chargeback"),
          created_at: at
        )
        ensure_current_suspension!(ticket, sale)
        record_chargeback!(entry, sale, payment, ticket)
        entry
      end
      success(outcome.is_a?(Core::BaseService::Result) ? outcome.value : outcome)
    rescue ArgumentError
      failure(chargeback_error(:invalid_idempotency_key))
    rescue Abort => error
      failure(error.business_error)
    rescue ActiveRecord::RecordNotFound
      failure(chargeback_error(:chargeback_sale_not_found, status: :not_found))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        chargeback_error(
          :chargeback_ledger_invalid,
          errors: error.record.errors.to_hash
        )
      )
    end

    private

    attr_reader :payment_id, :actor, :amount_minor, :at

    def lock_context
      payment = Orders::Payment.lock.find(payment_id)
      sale = ResaleSale.includes(:event, :seller_user).lock.find_by!(accepted_payment_id: payment.id)
      ticket = Ticketing::Ticket.includes(:event, :revocation, :ticket_suspensions).lock.find(sale.ticket_id)
      event = Events::Event.lock.find(sale.event_id)
      abort_with(:chargeback_payment_invalid) unless payment.order_id == sale.buyer_order_id
      abort_with(:chargeback_sale_not_found) unless sale.status == "completed"
      [ payment, sale, ticket, event ]
    end

    def validate_amount!(sale)
      amount = amount_minor || sale.gross_amount_minor
      abort_with(:chargeback_amount_invalid) unless amount.is_a?(Integer) && amount.positive?
      abort_with(:chargeback_amount_exceeded) if amount > sale.gross_amount_minor

      amount
    end

    def chargeback_key(sale, amount)
      return "marketplace-resale-chargeback-#{sale.id}-#{amount}" if @raw_idempotency_key.blank?

      Core::IdempotencyKey.new(@raw_idempotency_key).to_s
    end

    def ensure_current_suspension!(ticket, sale)
      return unless ticket.current_acquisition_order_item_id == sale.buyer_order_item_id

      active = Ticketing::TicketSuspension.lock.find_by(ticket_id: ticket.id, status: "active")
      if active
        abort_with(:chargeback_suspension_conflict) unless active.reason_code == "chargeback_review"
        return active
      end

      result = Ticketing::Suspensions::Open.call(
        ticket:,
        actor:,
        reason_code: "chargeback_review",
        review_deadline_at: 14.days.from_now,
        idempotency_key: "marketplace-chargeback-suspension-#{sale.id}"
      )
      abort_with(result.error) if result.failure?
      result.value
    end

    def record_chargeback!(entry, sale, payment, ticket)
      audit = Core::Audit::Record.call(
        audit_key: "marketplace-resale-chargeback-#{entry.id}",
        action: "marketplace.resale_chargeback.frozen",
        auditable_type: entry.class.name,
        auditable_id: entry.id,
        actor_type: actor&.class&.name,
        actor_id: actor&.id,
        audited_changes: { amount_minor: entry.amount_minor, type: entry.type },
        metadata: {
          sale_id: sale.id,
          payment_id: payment.id,
          ticket_id: sale.ticket_id,
          current_acquisition: sale.buyer_order_item_id == ticket.current_acquisition_order_item_id
        }
      )
      abort_with(audit.error) if audit.failure?

      publication = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_chargeback.frozen",
        aggregate: sale,
        payload: {
          sale_id: sale.id,
          ledger_entry_id: entry.id,
          payment_id: payment.id,
          ticket_id: sale.ticket_id,
          amount_minor: entry.amount_minor
        },
        idempotency_key: "marketplace-resale-chargeback-#{entry.id}"
      )
      abort_with(publication.error) if publication.failure?
    end

    def abort_with(key_or_error, errors: nil)
      error = key_or_error.is_a?(Core::BusinessError) ? key_or_error : chargeback_error(key_or_error, errors:)
      raise Abort, error
    end

    def chargeback_error(key, status: :conflict, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{key}"), code: key, status:, errors:
      )
    end
  end
end
