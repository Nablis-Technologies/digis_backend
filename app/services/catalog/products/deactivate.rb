# frozen_string_literal: true

module Catalog
  module Products
    # Marks an event product inactive (hidden from sale) without deleting it.
    class Deactivate < Core::BaseService
      def initialize(product:)
        @product = product
      end

      def call
        ActiveRecord::Base.transaction do
          @product.active = false
          unless @product.save
            return failure(Core::Error.new(@product.errors.full_messages.join(", ")))
          end

          success(@product)
        end
      rescue Core::Error => e
        failure(e)
      end
    end
  end
end
