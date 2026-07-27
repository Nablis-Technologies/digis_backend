# frozen_string_literal: true

require "test_helper"

module Events
  module Media
    class UpdateTest < ActiveSupport::TestCase
      def setup
        @event = events_events(:ready_listing)
        @user = core_users(:super_admin)
        @media = Events::EventMedia.create!(event: @event, created_by: @user, type: "gallery", position: 1) do |m|
          attach(m)
        end
      end

      def attach(media)
        media.file.attach(
          io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
          filename: "pixel.png", content_type: "image/png"
        )
      end

      test "updating media is idempotent with respect to the audit log" do
        attributes = { alt_text: "a cat", caption: "cute" }
        subject = -> { Events::Media::Update.call(media: @media, actor: @user, attributes: attributes, file: nil) }
        assert_audit_idempotent(
          subject,
          action: "event.media.updated",
          auditable_type: "Events::EventMedia",
          auditable_id: @media.id
        )
      end
    end
  end
end
