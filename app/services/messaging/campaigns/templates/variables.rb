# frozen_string_literal: true

module Messaging
  module Campaigns
    module Templates
      # Keeps interpolation limited to display-safe campaign values.
      module Variables
        ALLOWED = %w[event_name event_date venue_name ticket_link first_name organization_name].freeze
        TOKEN = /\{\{\s*([a-z_]+)\s*\}\}/.freeze

        class UnknownVariable < StandardError
          attr_reader :names

          def initialize(names)
            @names = names
            super("unknown campaign template variable: #{names.join(", ")}")
          end
        end

        module_function

        def validate!(content)
          unknown = extract(content) - ALLOWED
          raise UnknownVariable, unknown.uniq if unknown.any?

          true
        end

        def extract(content)
          content.to_s.scan(TOKEN).flatten.uniq
        end
      end
    end
  end
end
