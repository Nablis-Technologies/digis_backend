# frozen_string_literal: true

require "test_helper"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  test "encrypted fixtures are enabled in test" do
    assert Rails.application.config.active_record.encryption.encrypt_fixtures
  end

  test "sensitive event-platform parameter names are filtered" do
    filters = Rails.application.config.filter_parameters.map(&:to_s)

    %w[answer answers value consent qr_token lookup_code account_number account_name holder_name promotion_code code_ciphertext].each do |name|
      assert filters.any? { |filter| filter.include?(name) }, "expected #{name} to be filtered"
    end
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filtered.filter("code" => "OPENING10")["code"]
  end
end
