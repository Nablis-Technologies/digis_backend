# frozen_string_literal: true

require "test_helper"
require "fugit"
require "yaml"

class PrivateAttendeeExportsConfigurationTest < ActiveSupport::TestCase
  test "production schedules bounded attendee export expiry" do
    production = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")

    assert_equal "Ticketing::ExpireAttendeeExportsJob", production.fetch("expire_attendee_exports").fetch("class")
    assert_equal "*/5 * * * *", production.fetch("expire_attendee_exports").fetch("schedule")
  end

  test "production recurring schedules are supported by Solid Queue" do
    production = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")

    production.each do |key, configuration|
      schedule = Fugit.parse(configuration.fetch("schedule"), multi: :fail)

      assert_instance_of Fugit::Cron, schedule, "#{key} must use a cron-compatible schedule"
    end
  end

  test "private export storage rejects disk services" do
    service = ActiveStorage::Service::DiskService.new(root: Rails.root.join("tmp/private-export-config-test"))

    error = assert_raises(Core::PrivateAttendeeExports::InsecureStorage) do
      Core::PrivateAttendeeExports.validate_service!(service)
    end

    assert_equal I18n.t("core.private_attendee_exports.errors.insecure_storage"), error.message
  end
end
