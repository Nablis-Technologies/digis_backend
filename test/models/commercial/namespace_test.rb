# frozen_string_literal: true

require "test_helper"

module Commercial
  class NamespaceTest < ActiveSupport::TestCase
    test "application record is an abstract core record" do
      assert_operator Commercial::ApplicationRecord, :<, Core::ApplicationRecord
      assert Commercial::ApplicationRecord.abstract_class?
    end

    test "application controllers inherit from their platform boundaries" do
      assert_operator Commercial::ApplicationController, :<, Core::ApplicationController
      assert_operator ::Admin::Commercial::ApplicationController, :<, ::Admin::ApplicationController
    end

    test "fee schedule uses the commercial record boundary" do
      assert_operator Commercial::FeeSchedule, :<, Commercial::ApplicationRecord
    end
  end
end
