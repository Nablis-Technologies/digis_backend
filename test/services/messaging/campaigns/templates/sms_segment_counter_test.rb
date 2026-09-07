# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    module Templates
      class SmsSegmentCounterTest < ActiveSupport::TestCase
        test "counts GSM-7 single and concatenated messages" do
          assert_equal 1, SmsSegmentCounter.call("a" * 160)
          assert_equal 2, SmsSegmentCounter.call("a" * 161)
          assert_equal 2, SmsSegmentCounter.call("a" * 306)
          assert_equal 3, SmsSegmentCounter.call("a" * 307)
        end

        test "counts GSM-7 extension characters as two septets" do
          assert_equal 1, SmsSegmentCounter.call("{" * 80)
          assert_equal 2, SmsSegmentCounter.call("{" * 81)
        end

        test "counts Amharic and emoji by UTF-16 code units" do
          assert_equal 1, SmsSegmentCounter.call("ሰ" * 70)
          assert_equal 2, SmsSegmentCounter.call("ሰ" * 71)
          assert_equal 1, SmsSegmentCounter.call("😀" * 35)
          assert_equal 2, SmsSegmentCounter.call("😀" * 36)
          assert_equal 4, SmsSegmentCounter.call("😀" * 134)
          assert_equal 5, SmsSegmentCounter.call("😀" * 135)
        end

        test "email uses one credit regardless of body length" do
          assert_equal 1, SmsSegmentCounter.units_for(channel: "email", body: "x" * 10_000)
        end

        test "rejects a blank SMS body" do
          assert_raises(ArgumentError) { SmsSegmentCounter.call(" ") }
        end
      end
    end
  end
end
