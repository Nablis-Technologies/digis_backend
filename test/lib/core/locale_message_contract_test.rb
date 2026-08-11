# frozen_string_literal: true

require "test_helper"

module Core
  class LocaleMessageContractTest < ActiveSupport::TestCase
    DIRECT_MESSAGE_PATTERNS = {
      response: /render_(?:success|error)\s*\(\s*["']/m,
      business_error: /Core::BusinessError\.new\s*\(\s*["']/m,
      validation: /errors\.add\s*\([^,\n]+,\s*(?!I18n\.t\s*\()["']/m,
      exception: /(?:raise|fail)\s+[A-Z][\w:]*(?:\s*,|\s+)[\s]*["']/m,
      guard: /ensure!\s*\([^,\n]+,\s*(?!I18n\.t\s*\()["']/m
    }.freeze

    test "application message boundaries do not contain hardcoded messages" do
      violations = []

      Rails.root.glob("app/**/*.rb").each do |path|
        source = path.read
        DIRECT_MESSAGE_PATTERNS.each do |category, pattern|
          match = pattern.match(source)
          next unless match

          line = source[0...match.begin(0)].count("\n") + 1
          violations << "#{path.relative_path_from(Rails.root)}:#{line} (#{category})"
        end
      end

      assert_empty violations, "hardcoded application messages: #{violations.join(', ')}"
    end

    test "literal application translation keys exist" do
      missing = []

      Rails.root.glob("app/**/*.rb").each do |path|
        path.read.scan(/I18n\.t\(\s*(?:"([^"]+)"|:"([^"]+)")/) do |quoted, symbol|
          key = quoted || symbol
          next if key.include?('#{')
          next if I18n.exists?(key)

          missing << "#{path.relative_path_from(Rails.root)}:#{key}"
        end
      end

      assert_empty missing, "missing locale keys: #{missing.join(', ')}"
    end
  end
end
