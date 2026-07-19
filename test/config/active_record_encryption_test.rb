# frozen_string_literal: true

require "test_helper"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  test "encrypted fixtures are enabled in test" do
    assert Rails.application.config.active_record.encryption.encrypt_fixtures
  end

  test "sensitive event-platform parameter names are filtered" do
    filters = Rails.application.config.filter_parameters.map(&:to_s)

    %w[answer consent qr_token lookup_code account_token holder_name].each do |name|
      assert filters.any? { |filter| filter.include?(name) }, "expected #{name} to be filtered"
    end
  end
end
