# frozen_string_literal: true

module Marketplace
  # Creates one normal refund obligation for every paid acquisition in a
  # package's immutable resale chain. Ticket ownership and credential history
  # remain untouched; the original acquisition is the only refund item that
  # carries the issued ticket foreign key, while later resale rows refund their
  # own order/payment snapshots.
  class CancelAcquisitionChainValue < Core::BaseService
    class Abort < Core::Error
      attr_reader :business_error

      def initialize(business_error)
        @business_error = business_error
        super(business_error.message)
      end
    end

    def initialize(ticket:, idempotency_key:, event_date: nil, event_cancellation: nil, at: Time.current)
      @ticket_id = ticket.id
      @raw_idempotency_key = idempotency_key
      @event_date_id = event_date&.id
      @event_cancellation_id = event_cancellation&.id
      @event_cancellation = event_cancellation
      @at = at.to_time.utc
    rescue NoMethodError, ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(chain_error(:invalid_idempotency_key)) if @initialization_error

      idempotency_key = Core::IdempotencyKey.new(@raw_idempotency_key)
      outcome = ActiveRecord::Base.transaction do
        ticket = lock_ticket
        event = Events::Event.lock.find(ticket.event_id)
        sales = lock_sales(ticket)
        ensure_date_scope_supported!(sales)
        acquisitions = acquisition_chain(ticket, sales)
        acquisitions = lock_acquisition_payments_and_refunds(acquisitions)

        refunds = acquisitions.map do |acquisition|
          create_refund!(ticket:, acquisition:, event:, idempotency_key:)
        end
        refunds_by_item_id = acquisitions.zip(refunds).to_h do |acquisition, refund|
          [ acquisition.fetch(:item).id, refund ]
        end
        ledger_entries = lock_seller_ledger_entries(sales)
        sales.each do |sale|
          cancel_sale!(sale, ticket, refunds_by_item_id, ledger_entries, idempotency_key)
        end
        success(refunds)
      end
      outcome
    rescue ArgumentError
      failure(chain_error(:invalid_idempotency_key))
    rescue Abort => error
      failure(error.business_error)
    rescue ActiveRecord::RecordNotFound
      failure(chain_error(:acquisition_chain_not_found, status: :not_found))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        chain_error(
          :acquisition_chain_invalid,
          errors: error.record.errors.to_hash
        )
      )
    end

    private

    attr_reader :ticket_id, :event_date_id, :event_cancellation, :at

    def lock_ticket
      Ticketing::Ticket.includes(:event, :order_item, :current_acquisition_order_item).lock.find(ticket_id)
    end

    def lock_sales(ticket)
      ResaleSale.includes(:event, :seller_user).where(ticket_id: ticket.id).order(:resale_number, :id).lock.to_a
    end

    def ensure_date_scope_supported!(sales)
      return unless event_date_id && sales.any?

      # The current refund-item database contract ties a date refund to the
      # credential ticket. Resale acquisition rows intentionally belong to a
      # different order and cannot carry that foreign key, so fail the whole
      # chain before creating a partial set of obligations.
      abort_with(:date_scoped_resale_refund_unsupported)
    end

    def acquisition_chain(ticket, sales)
      item_ids = sales.flat_map { |sale| [ sale.buyer_order_item_id, sale.seller_acquisition_order_item_id ] }
      item_ids << ticket.order_item_id
      items = Orders::OrderItem.includes(:order).where(id: item_ids.compact.uniq).order(:id).lock.to_a.index_by(&:id)
      sales_by_buyer_item = sales.index_by(&:buyer_order_item_id)
      current_item_id = ticket.current_acquisition_order_item_id || ticket.order_item_id
      visited = []
      chain = []

      loop do
        abort_with(:acquisition_chain_invalid) if current_item_id.blank? || visited.include?(current_item_id)

        item = items[current_item_id]
        abort_with(:acquisition_chain_invalid) unless item
        visited << current_item_id
        sale = sales_by_buyer_item[current_item_id]
        chain << { item:, sale: }
        break unless sale

        current_item_id = sale.seller_acquisition_order_item_id
      end

      abort_with(:acquisition_chain_invalid) unless chain.last.fetch(:item).id == ticket.order_item_id
      chain.reverse
    end

    def lock_acquisition_payments_and_refunds(acquisitions)
      explicit_payment_ids = acquisitions.filter_map { |acquisition| acquisition[:sale]&.accepted_payment_id }
      primary_order_ids = acquisitions.filter_map { |acquisition| acquisition[:sale].nil? && acquisition[:item].order_id }
      payment_scope = Orders::Payment.where(id: explicit_payment_ids)
      unless primary_order_ids.empty?
        payment_scope = payment_scope.or(
          Orders::Payment.where(order_id: primary_order_ids, status: "succeeded").where.not(accepted_at: nil)
        )
      end
      payments = payment_scope.order(:id).lock.to_a
      payments_by_id = payments.index_by(&:id)
      payments_by_order = payments.group_by(&:order_id)
      acquisitions.each do |acquisition|
        sale = acquisition[:sale]
        order_id = sale ? sale.buyer_order_id : acquisition[:item].order_id
        payment = if sale
          payments_by_id[sale.accepted_payment_id]
        else
          payments_by_order.fetch(order_id, []).max_by { |candidate| [ candidate.attempt_number, candidate.id ] }
        end
        abort_with(:acquisition_payment_missing) unless payment
        abort_with(:acquisition_payment_invalid) unless payment.order_id == order_id
        acquisition[:payment] = payment
      end

      payment_ids = acquisitions.map { |acquisition| acquisition.fetch(:payment).id }.uniq
      locked_items = Orders::OrderItem.where(order_id: acquisitions.map { |acquisition| acquisition[:item].order_id }.uniq)
        .order(:id).lock.to_a
      locked_tickets = Ticketing::Ticket.where(order_item_id: locked_items.map(&:id)).order(:id).lock.to_a
      prior_refunds = Orders::Refund.where(payment_id: payment_ids).order(:id).lock.to_a
      prior_items = Orders::RefundItem.where(refund_id: prior_refunds.map(&:id)).order(:id).lock.to_a
      locked_adjustments = Orders::OrderAdjustment.where(
        order_id: locked_items.map(&:order_id).uniq
      ).order(:id).lock.to_a
      locked_dates = event_date_id ? [ Events::EventDate.lock.find(event_date_id) ] : []

      acquisitions.each do |acquisition|
        payment = acquisition.fetch(:payment)
        item = acquisition.fetch(:item)
        refunds = prior_refunds.select { |refund| refund.payment_id == payment.id }
        acquisition[:refund_scope] = {
          payment:,
          locked_items: locked_items.select { |candidate| candidate.order_id == item.order_id },
          locked_tickets: locked_tickets.select do |candidate|
            locked_items.any? { |locked_item| locked_item.id == candidate.order_item_id && locked_item.order_id == item.order_id }
          end,
          locked_dates:,
          prior_refunds: refunds,
          prior_items: prior_items.select { |candidate| refunds.any? { |refund| refund.id == candidate.refund_id } },
          locked_adjustments: locked_adjustments.select { |candidate| candidate.order_id == item.order_id }
        }
      end
      acquisitions
    end

    def create_refund!(ticket:, acquisition:, event:, idempotency_key:)
      item = acquisition.fetch(:item)
      sale = acquisition[:sale]
      payment = acquisition.fetch(:payment)
      refund_key = "marketplace-acquisition-chain-refund-#{ticket.id}-#{item.id}"
      result = Orders::CreateItemRefund.call(
        payment:,
        order_item: item,
        ticket: sale ? nil : ticket,
        quantity: item.quantity,
        reason_code: "event_cancellation",
        idempotency_key: refund_key,
        event_date: event_date_for(event),
        event_cancellation: event_cancellation,
        restock: false,
        preloaded_scope: acquisition.fetch(:refund_scope)
      )
      abort_with(result.error) if result.failure?
      result.value
    end

    def event_date_for(event)
      return unless event_date_id

      date = Events::EventDate.lock.find(event_date_id)
      abort_with(:acquisition_chain_invalid) unless date.event_id == event.id
      date
    end

    def lock_seller_ledger_entries(sales)
      sale_ids = sales.map(&:id)
      entries = SellerLedgerEntry.where(
        resale_sale_id: sale_ids, type: %w[resale_proceeds marketplace_fee]
      ).order(:resale_sale_id, :created_at, :id).lock.to_a
      reversals = SellerLedgerEntry.where(reverses_entry_id: entries.map(&:id)).order(:id).lock.to_a
      {
        entries: entries.group_by(&:resale_sale_id),
        reversals: reversals.index_by(&:reverses_entry_id)
      }
    end

    def cancel_sale!(sale, ticket, refunds_by_item_id, ledger_entries, idempotency_key)
      refund = refunds_by_item_id[sale.buyer_order_item_id]
      abort_with(:acquisition_chain_invalid) unless refund

      entries = ledger_entries.fetch(:entries).fetch(sale.id, [])
      abort_with(:acquisition_ledger_missing) unless entries.map(&:type).sort == %w[marketplace_fee resale_proceeds]

      entries.each do |entry|
        reversal = ledger_entries.fetch(:reversals)[entry.id]
        next if reversal

        SellerLedgerEntry.create!(
          seller_user: sale.seller_user,
          event: sale.event,
          resale_sale: sale,
          reverses_entry: entry,
          type: "cancellation_reversal",
          amount_minor: -entry.amount_minor,
          currency: entry.currency,
          available_at: at,
          idempotency_key: "marketplace-acquisition-chain-reversal-#{sale.id}-#{entry.id}",
          description: I18n.t("marketplace.resale.ledger_descriptions.cancellation_reversal"),
          created_at: at
        )
      end

      return if sale.status == "cancelled"
      abort_with(:acquisition_chain_invalid) unless sale.status == "completed"

      # The immutable sale snapshot is already validated and the database
      # trigger permits only lifecycle status changes; bypassing full model
      # validation avoids reloading every belongs_to association in the chain.
      sale.update_columns(status: "cancelled", updated_at: at)
      record_cancellation!(sale, ticket, idempotency_key)
    end

    def record_cancellation!(sale, ticket, idempotency_key)
      audit = Core::Audit::Record.call(
        audit_key: "marketplace-resale-sale-cancelled-#{sale.id}",
        action: "marketplace.resale_sale.cancelled",
        auditable_type: sale.class.name,
        auditable_id: sale.id,
        actor_type: nil,
        actor_id: nil,
        audited_changes: { status: "cancelled" },
        metadata: {
          ticket_id: ticket.id,
          event_id: sale.event_id,
          idempotency_key: idempotency_key.to_s
        }
      )
      abort_with(audit.error) if audit.failure?

      publication = Core::Outbox::Publish.call(
        topic: "marketplace",
        event_type: "marketplace.resale_sale.cancelled",
        aggregate: sale,
        payload: {
          sale_id: sale.id,
          ticket_id: ticket.id,
          event_id: sale.event_id,
          refund_order_item_id: sale.buyer_order_item_id
        },
        idempotency_key: "marketplace-resale-sale-cancelled-#{sale.id}"
      )
      abort_with(publication.error) if publication.failure?
    end

    def abort_with(key_or_error, errors: nil)
      error = key_or_error.is_a?(Core::BusinessError) ? key_or_error : chain_error(key_or_error, errors:)
      raise Abort, error
    end

    def chain_error(key, status: :conflict, errors: nil)
      Core::BusinessError.new(
        I18n.t("marketplace.resale.errors.#{key}"), code: key, status:, errors:
      )
    end
  end
end
