# frozen_string_literal: true

require "erb"

module Messaging
  module Campaigns
    module Templates
      # Replaces approved campaign tokens with recipient and campaign context.
      module Interpolator
        module_function

        FALLBACKS = { "first_name" => "there" }.freeze

        def call(content, values:, escape_values: false)
          Variables.validate!(content)
          normalized_values = values.to_h.stringify_keys
          content.to_s.gsub(Variables::TOKEN) do
            token = Regexp.last_match(1)
            value = normalized_values[token].presence || FALLBACKS.fetch(token, "")
            escape_values ? ERB::Util.html_escape(value) : value
          end
        end
      end
    end
  end
end
