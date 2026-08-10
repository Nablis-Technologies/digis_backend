# frozen_string_literal: true

require "test_helper"

class Core::PrivateAttendeeExportsTest < ActiveSupport::TestCase
  test "rejects a public storage service" do
    service = Struct.new(:public?).new(true)

    assert_raises(Core::PrivateAttendeeExports::InsecureStorage) do
      Core::PrivateAttendeeExports.validate_service!(service)
    end
  end

  test "rejects a mirror whose primary service is public" do
    public_primary = Struct.new(:public?).new(true)
    mirror = Struct.new(:primary, :mirrors, :public?).new(public_primary, [], false)

    assert_raises(Core::PrivateAttendeeExports::InsecureStorage) do
      Core::PrivateAttendeeExports.validate_service!(mirror)
    end
  end
end
