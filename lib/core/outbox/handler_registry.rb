# frozen_string_literal: true

module Core
  module Outbox
    # Stores ordered exact and namespace handlers in separate maps. Bracket
    # access remains available for existing initializer diagnostics while
    # register supports ordered composition.
    class HandlerRegistry
      Entry = Data.define(:priority, :sequence, :handler)

      # Invokes each registered consumer in deterministic order. A later
      # failure can replay earlier consumers, so every consumer must be
      # idempotent at its own durable boundary.
      class HandlerChain
        def initialize(entries)
          @entries = entries.freeze
        end

        def call(event)
          result = nil
          @entries.each do |entry|
            result = entry.handler.call(event)
            next unless result.respond_to?(:failure?) && result.failure?

            error = result.respond_to?(:error) ? result.error : nil
            raise error if error.is_a?(Exception)

            raise Core::Error, I18n.t("core.errors.outbox_handler_failed")
          end
          result
        end
      end

      def initialize
        @exact_handlers = Hash.new { |hash, key| hash[key] = [] }
        @namespace_handlers = Hash.new { |hash, key| hash[key] = [] }
        @sequence = 0
      end

      def register(event_type, priority: 100, &handler)
        register_into(@exact_handlers, event_type, priority:, handler:)
      end

      def register_namespace(namespace, priority: 100, &handler)
        register_into(@namespace_handlers, namespace, priority:, handler:)
      end

      def fetch(event_type)
        chain_for(@exact_handlers[event_type.to_s])
      end

      def fetch_namespace(namespace)
        chain_for(@namespace_handlers[namespace.to_s])
      end

      def [](event_type)
        fetch(event_type)
      end

      def []=(event_type, handler)
        @exact_handlers[event_type.to_s] = []
        register(event_type) { |event| handler.call(event) }
      end

      def key?(event_type)
        exact_key?(event_type) || namespace_key?(event_type)
      end

      # Existing operational tests and initializer diagnostics use Hash-style
      # membership checks while the registry migration is rolled out.
      def include?(event_type)
        key?(event_type)
      end

      def exact_key?(event_type)
        key = event_type.to_s
        @exact_handlers.key?(key) && @exact_handlers[key].any?
      end

      def namespace_key?(namespace)
        key = namespace.to_s
        @namespace_handlers.key?(key) && @namespace_handlers[key].any?
      end

      private

      def register_into(store, key, priority:, handler:)
        raise ArgumentError, I18n.t("core.errors.outbox_handler_required") unless handler.respond_to?(:call)

        @sequence += 1
        store[key.to_s] << Entry.new(priority: priority.to_i, sequence: @sequence, handler:)
        handler
      end

      def chain_for(entries)
        return if entries.blank?

        HandlerChain.new(entries.sort_by { |entry| [ entry.priority, entry.sequence ] })
      end
    end
  end
end
