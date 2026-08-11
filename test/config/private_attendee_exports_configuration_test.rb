# frozen_string_literal: true

require "test_helper"
require "yaml"

class PrivateAttendeeExportsConfigurationTest < ActiveSupport::TestCase
  test "production schedules bounded attendee export expiry" do
    production = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")

    assert_equal "Ticketing::ExpireAttendeeExportsJob", production.fetch("expire_attendee_exports").fetch("class")
    assert_equal "every five minutes", production.fetch("expire_attendee_exports").fetch("schedule")
  end

  test "private export storage rejects disk services" do
    service = ActiveStorage::Service::DiskService.new(root: Rails.root.join("tmp/private-export-config-test"))

    error = assert_raises(Core::PrivateAttendeeExports::InsecureStorage) do
      Core::PrivateAttendeeExports.validate_service!(service)
    end

    assert_equal I18n.t("core.private_attendee_exports.errors.insecure_storage"), error.message
  end
end
