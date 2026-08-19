# frozen_string_literal: true

require "open3"
require "test_helper"

class PaymentProvidersBootTest < ActiveSupport::TestCase
  test "boots successfully when Chapa is enabled in the preview environment" do
    environment = {
      "RAILS_ENV" => "test",
      "RENDER_PREVIEW" => "true",
      "RENDER_PREVIEW_DATABASE_URL" => ENV.fetch("DATABASE_URL", "postgresql://localhost/digis_backend_test"),
      "CHAPA_ENABLED" => "true",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => "CHASECK_TEST-boot-test",
      "CHAPA_WEBHOOK_SECRET" => "webhook-secret"
    }
    _stdout, stderr, status = Open3.capture3(
      environment,
      Rails.root.join("bin/rails").to_s,
      "runner",
      "puts 'booted'"
    )

    assert_predicate status, :success?, stderr
  end
end
