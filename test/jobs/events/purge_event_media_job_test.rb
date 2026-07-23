# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  class PurgeEventMediaJobTest < ActiveJob::TestCase
    include ActiveJob::TestHelper

    test "purges the blob for a removed media id" do
      event = events_events(:ready_listing)
      user = core_users(:super_admin)
      media = Events::EventMedia.create!(event:, created_by: user, type: "gallery", position: 1) do |m|
        m.file.attach(
          io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
          filename: "pixel.png", content_type: "image/png"
        )
      end
      blob_id = media.file.blob_id
      refute_nil blob_id
      media.destroy!

      Events::PurgeEventMediaJob.perform_now(blob_id)

      assert_nil ActiveStorage::Blob.find_by(id: blob_id)
    end

    test "does nothing for a missing blob id" do
      assert_nothing_raised do
        Events::PurgeEventMediaJob.perform_now("00000000-0000-0000-0000-000000000000")
      end
    end
  end
end
