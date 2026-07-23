# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  module Media
    class ReorderTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      def setup
        @event = events_events(:ready_listing)
        @user = core_users(:super_admin)
        @a = create_gallery(position: 1)
        @b = create_gallery(position: 2)
        @c = create_gallery(position: 3)
        @cover = create_cover
      end

      def create_gallery(position:)
        Events::EventMedia.create!(event: @event, created_by: @user, type: "gallery", position: position) do |m|
          attach(m)
        end
      end

      def create_cover
        Events::EventMedia.create!(event: @event, created_by: @user, type: "cover", position: 0) do |m|
          attach(m)
        end
      end

      def attach(media)
        media.file.attach(
          io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
          filename: "pixel.png", content_type: "image/png"
        )
      end

      test "reorders gallery positions sequentially without collisions" do
        result = Events::Media::Reorder.call(
          event: @event, actor: @user, ordered_ids: [ @c.id, @a.id, @b.id ]
        )
        assert result.success?, result.error.inspect
        assert_equal 1, @c.reload.position
        assert_equal 2, @a.reload.position
        assert_equal 3, @b.reload.position
      end

      test "keeps the cover pinned at position zero" do
        result = Events::Media::Reorder.call(
          event: @event, actor: @user, ordered_ids: [ @c.id, @a.id, @b.id ]
        )
        assert result.success?
        assert_equal 0, @cover.reload.position
      end

      test "writes an audit entry on success" do
        assert_difference -> { Core::AuditLog.count }, 1 do
          Events::Media::Reorder.call(
            event: @event, actor: @user, ordered_ids: [ @c.id, @a.id, @b.id ]
          )
        end
        assert Core::AuditLog.exists?(
          action: "event.media.reordered", auditable_type: "Events::Event", auditable_id: @event.id
        )
      end

      test "rejects an empty ordered_ids list" do
        result = Events::Media::Reorder.call(event: @event, actor: @user, ordered_ids: [])
        assert result.failure?
        assert_equal "invalid", result.error.code
      end

      test "rejects ordered_ids containing unknown ids" do
        unknown = "00000000-0000-0000-0000-000000000000"
        result = Events::Media::Reorder.call(
          event: @event, actor: @user, ordered_ids: [ @a.id, unknown ]
        )
        assert result.failure?
        assert_equal "invalid", result.error.code
        assert_includes result.error.errors[:ordered_ids].first, "unknown ids"
      end

      test "reordering is idempotent with respect to the audit log" do
        subject = -> { Events::Media::Reorder.call(event: @event, actor: @user, ordered_ids: [ @c.id, @a.id, @b.id ]) }
        assert_audit_idempotent(
          subject,
          action: "event.media.reordered",
          auditable_type: "Events::Event",
          auditable_id: @event.id
        )
      end
    end
  end
end
