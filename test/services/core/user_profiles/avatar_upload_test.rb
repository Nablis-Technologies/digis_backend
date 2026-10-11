require "test_helper"
require "timeout"

module Core
  module UserProfiles
    class AvatarUploadTest < ActiveSupport::TestCase
      test "serializes image-processing work within the web process" do
        assert_respond_to AvatarUpload, :with_processing_lock

        first_entered = Queue.new
        release_first = Queue.new
        second_starting = Queue.new
        second_entered = Queue.new

        first = Thread.new do
          AvatarUpload.with_processing_lock do
            first_entered << true
            release_first.pop
          end
        end
        first_entered.pop

        second = Thread.new do
          second_starting << true
          AvatarUpload.with_processing_lock { second_entered << true }
        end
        second_starting.pop

        Timeout.timeout(2) do
          Thread.pass until second.status == "sleep" || second.status == false
        end

        assert_predicate second_entered, :empty?
        assert_predicate second, :alive?

        release_first << true
        assert_equal true, second_entered.pop
        first.join
        second.join
      ensure
        release_first << true if first&.alive?
        first&.join
        second&.join
      end
    end
  end
end
