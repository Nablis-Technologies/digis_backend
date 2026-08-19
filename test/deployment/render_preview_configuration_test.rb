# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

class RenderPreviewConfigurationTest < ActiveSupport::TestCase
  test "blueprint defines one free web service and one free database" do
    blueprint = YAML.safe_load(Rails.root.join("render.yaml").read, aliases: true)
    service = blueprint.fetch("services").sole
    database = blueprint.fetch("databases").sole

    assert_equal "web", service.fetch("type")
    assert_equal "docker", service.fetch("runtime")
    assert_equal "free", service.fetch("plan")
    assert_equal "./Dockerfile", service.fetch("dockerfilePath")
    assert_equal "/up", service.fetch("healthCheckPath")
    assert_equal "feat/launch-hardening-telemetry", service.fetch("branch")
    assert_equal "free", database.fetch("plan")
    env_vars = service.fetch("envVars").to_h { |entry| [ entry.fetch("key"), entry["value"] ] }
    assert_equal "0", env_vars.fetch("WEB_CONCURRENCY")
    assert_equal "3", env_vars.fetch("RAILS_MAX_THREADS")
    assert_equal "1", env_vars.fetch("JOB_THREADS")
    keys = env_vars.keys
    assert_includes keys, "RENDER_PREVIEW"
    assert_includes keys, "RENDER_PREVIEW_DATABASE_URL"
    assert_includes keys, "SOLID_QUEUE_IN_PUMA"
    assert_includes keys, "RAILS_MASTER_KEY"
    assert_includes keys, "CORE_ENCRYPTION_PRIMARY_KEY"
    assert_includes keys, "CORE_ENCRYPTION_DETERMINISTIC_KEY"
    assert_includes keys, "CORE_ENCRYPTION_KEY_DERIVATION_SALT"
    assert_includes keys, "ATTENDEE_EXPORT_HMAC_KEYS"
    assert_includes keys, "TICKETING_QR_SIGNING_KEYS"
    assert_includes keys, "TICKETING_QR_CURRENT_KID"
    assert_includes keys, "FIL_ENDPOINT"
    assert_includes keys, "FIL_REGION"
    assert_includes keys, "FIL_BUCKET"
    assert_includes keys, "FIL_ACCESS_KEY"
    assert_includes keys, "FIL_SECRET_KEY"
  end

  test "blueprint does not contain literal credentials" do
    content = Rails.root.join("render.yaml").read

    refute_match(/^\s*password\s*:/i, content)
    refute_match(/^\s*(token|private_key)\s*:/i, content)
  end

  test "preview uses one database URL for every production role" do
    configurations = evaluate_database_configuration(
      preview: true, url: "postgres://render-preview.example/db"
    )

    %w[primary cache queue cable].each do |role|
      configuration = configurations.fetch(role)
      assert_equal "postgres://render-preview.example/db", configuration.fetch("url")
      assert_nil configuration["database"], "#{role} must inherit the preview URL database"
    end
  end

  test "non-preview production configuration retains explicit database roles" do
    configurations = evaluate_database_configuration(preview: false, url: nil)

    assert_equal "digis_backend_production", configurations.fetch("primary").fetch("database")
    assert_equal "digis_backend_production_cache", configurations.fetch("cache").fetch("database")
    assert_equal "digis_backend_production_queue", configurations.fetch("queue").fetch("database")
    assert_equal "digis_backend_production_cable", configurations.fetch("cable").fetch("database")
    configurations.each_value { |configuration| assert_nil configuration["url"] }
  end

  test "preview configuration fails when its database URL is missing" do
    error = assert_raises(RuntimeError) do
      evaluate_database_configuration(preview: true, url: nil)
    end

    assert_equal "RENDER_PREVIEW_DATABASE_URL is required when RENDER_PREVIEW=true", error.message
  end

  test "preview uses a private S3-compatible storage service" do
    storage = evaluate_storage_configuration(preview: true)
    private_exports = storage.fetch("private_exports")

    assert_equal "S3", private_exports.fetch("service")
    assert_equal "https://eu-west-1.s3.fil.one", private_exports.fetch("endpoint")
    assert_equal "eu-west-1", private_exports.fetch("region")
    assert_equal "preview-bucket", private_exports.fetch("bucket")
    assert_equal "preview-access", private_exports.fetch("access_key_id")
    assert_equal "preview-secret", private_exports.fetch("secret_access_key")
  end

  test "non-preview private export storage remains local disk" do
    private_exports = evaluate_storage_configuration(preview: false).fetch("private_exports")

    assert_equal "Disk", private_exports.fetch("service")
    assert_match(%r{tmp/private_exports\z}, private_exports.fetch("root"))
  end

  test "Gemfile declares the S3 Active Storage adapter" do
    assert_includes Rails.root.join("Gemfile").read, 'gem "aws-sdk-s3", require: false'
  end

  test "preview entrypoint prepares shared auxiliary schemas idempotently" do
    entrypoint = Rails.root.join("bin/docker-entrypoint").read

    assert_includes entrypoint, 'if [ "${RENDER_PREVIEW}" == "true" ]'
    assert_includes entrypoint, 'prepare_preview_schema "cache" "solid_cache_entries"'
    assert_includes entrypoint, 'prepare_preview_schema "queue" "solid_queue_recurring_tasks"'
    assert_includes entrypoint, 'prepare_preview_schema "cable" "solid_cable_messages"'
    assert_includes entrypoint, "DISABLE_DATABASE_ENVIRONMENT_CHECK=1 SCHEMA_FORMAT=ruby"
    assert_includes entrypoint, 'SCHEMA="db/${database}_schema.rb"'
    assert_includes entrypoint, "db:schema:load:${database}"
  end

  test "production URL defaults are environment-backed" do
    production = Rails.root.join("config/environments/production.rb").read

    assert_includes production, 'ENV.fetch("APP_HOST", "example.com")'
    assert_includes production, 'ENV.fetch("APP_PROTOCOL", "https")'
    assert_includes production, "config.action_mailer.default_url_options"
    assert_includes production, "Rails.application.routes.default_url_options"
  end

  private

  def evaluate_database_configuration(preview:, url:)
    previous_preview = ENV["RENDER_PREVIEW"]
    previous_url = ENV["RENDER_PREVIEW_DATABASE_URL"]
    ENV["RENDER_PREVIEW"] = preview ? "true" : nil
    ENV["RENDER_PREVIEW_DATABASE_URL"] = url
    YAML.safe_load(
      ERB.new(Rails.root.join("config/database.yml").read).result,
      aliases: true
    ).fetch("production")
  ensure
    ENV["RENDER_PREVIEW"] = previous_preview
    ENV["RENDER_PREVIEW_DATABASE_URL"] = previous_url
  end

  def evaluate_storage_configuration(preview:)
    variables = {
      "RENDER_PREVIEW" => preview ? "true" : nil,
      "FIL_ENDPOINT" => "https://eu-west-1.s3.fil.one",
      "FIL_REGION" => "eu-west-1",
      "FIL_BUCKET" => "preview-bucket",
      "FIL_ACCESS_KEY" => "preview-access",
      "FIL_SECRET_KEY" => "preview-secret"
    }
    previous = variables.to_h { |key, value| [ key, ENV[key] ] }
    variables.each { |key, value| ENV[key] = value }
    YAML.safe_load(
      ERB.new(Rails.root.join("config/storage.yml").read).result,
      aliases: true
    )
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end
end
