# frozen_string_literal: true

require "test_helper"

module Events
  module Media
    class ReadinessTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @user = core_users(:super_admin)
      end

      def attach_cover(alt_text:)
        media = Events::EventMedia.create!(event: @event, created_by: @user, type: "cover", position: 0, alt_text: alt_text) do |m|
          m.file.attach(
            io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
            filename: "pixel.png", content_type: "image/png"
          )
        end
        media.file.blob.update_column(:metadata, { "analyzed" => true, "width" => 100, "height" => 100 })
        media.file.blob.reload
        media
      end

      test "fails when no cover exists" do
        result = Events::Media::Readiness.call(event: @event)
        assert result.failure?
        assert_equal "media_not_ready", result.error.code
      end

      test "fails when the cover lacks alt text" do
        attach_cover(alt_text: "")
        result = Events::Media::Readiness.call(event: @event)
        assert result.failure?
      end

      test "succeeds with an analyzed cover and alt text" do
        attach_cover(alt_text: "Main stage")
        result = Events::Media::Readiness.call(event: @event)
        assert result.success?, result.error.inspect
      end
    end
  end
end
