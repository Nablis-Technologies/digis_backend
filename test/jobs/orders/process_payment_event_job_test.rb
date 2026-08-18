# frozen_string_literal: true

require "test_helper"

module Orders
  class ProcessPaymentEventJobTest < ActiveJob::TestCase
    test "delegates only the durable inbox id to the processing command" do
      event_id = SecureRandom.uuid
      received_ids = []
      original_call = Orders::ProcessPaymentEvent.method(:call)

      Orders::ProcessPaymentEvent.define_singleton_method(:call) do |event_id:|
        received_ids << event_id
        Core::BaseService::Result.success
      end
      begin
        Orders::ProcessPaymentEventJob.perform_now(event_id)
      ensure
        Orders::ProcessPaymentEvent.define_singleton_method(:call, original_call)
      end

      assert_equal [ event_id ], received_ids
    end
  end
end
