# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    module Templates
      class UpsertTest < ActiveSupport::TestCase
        test "uses the scope-neutral template command name" do
          assert_equal "Messaging::Campaigns::Templates::Upsert", Upsert.name
        end
      end
    end
  end
end
