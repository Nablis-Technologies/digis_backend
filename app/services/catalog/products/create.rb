# frozen_string_literal: true

module Catalog
  module Products
    # Creates an event product. Ticket products require a `ticket_type_attributes`
    # hash so the one-to-one `Ticketing::TicketType` row is created atomically in
    # the same transaction.
    class Create < Core::BaseService
      def initialize(event:, attributes:, ticket_type_attributes: nil)
        @event = event
        @attributes = attributes
        @ticket_type_attributes = ticket_type_attributes
      end

      def call
        ActiveRecord::Base.transaction do
          @product = Catalog::EventProduct.new(@attributes.merge(event: @event))

          if @product.ticket?
            return failure(Core::Error.new("ticket_type_attributes are required for ticket products")) if @ticket_type_attributes.blank?

            @product.build_ticket_type(@ticket_type_attributes)
          end

          unless @product.valid? && ticket_type_valid?
            return failure(Core::Error.new(@product.errors.full_messages.join(", ")))
          end

          @product.save!
          @product.ticket_type&.save! if @product.ticket_type&.new_record?

          success(@product)
        end
      rescue Core::Error => e
        failure(e)
      rescue ActiveRecord::RecordInvalid => e
        failure(Core::Error.new(e.record.errors.full_messages.join(", ")))
      end

      private

      def ticket_type_valid?
        return true if @product.ticket_type.blank?
        return true if @product.ticket_type.valid?

        @product.ticket_type.errors.each { |error| @product.errors.import(error) }
        false
      end
    end
  end
end
