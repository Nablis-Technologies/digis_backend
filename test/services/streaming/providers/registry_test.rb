# frozen_string_literal: true

require "test_helper"

module Streaming
  module Providers
    class RegistryTest < ActiveSupport::TestCase
      test "returns the enabled YouTube adapter" do
        adapter = Registry.fetch("youtube")

        assert_instance_of YouTubeAdapter, adapter
      end

      test "rejects unknown providers" do
        assert_raises(UnknownProvider) { Registry.fetch("internal") }
      end
    end
  end
end
