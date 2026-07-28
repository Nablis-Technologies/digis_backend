# frozen_string_literal: true

require "test_helper"

class Events::EventMediaTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @user = core_users(:super_admin)
  end

  def attach_image(media, filename: "pixel.png", content_type: "image/png")
    media.file.attach(
      io: File.open(Rails.root.join("test/fixtures/files/#{filename}")),
      filename: filename,
      content_type: content_type
    )
  end

  test "inheritance_column is disabled (no STI)" do
    assert Events::EventMedia.inheritance_column.blank?
  end

  test "type must be cover or gallery" do
    media = Events::EventMedia.new(event: @event, created_by: @user, type: "banner", position: 1)
    refute media.valid?
    assert media.errors[:type].present?
  end

  test "position must be nonnegative" do
    media = Events::EventMedia.new(event: @event, created_by: @user, type: "gallery", position: -1)
    refute media.valid?
    assert media.errors[:position].present?
  end

  test "cover must use position zero" do
    media = Events::EventMedia.new(event: @event, created_by: @user, type: "cover", position: 3)
    media.valid?
    assert media.errors[:position].present?
  end

  test "requires an attached image" do
    media = Events::EventMedia.new(event: @event, created_by: @user, type: "gallery", position: 1)
    refute media.valid?
    assert media.errors[:file].present?
  end

  test "rejects non-image content types such as svg" do
    media = Events::EventMedia.new(event: @event, created_by: @user, type: "gallery", position: 1)
    attach_image(media, filename: "sample.svg", content_type: "image/svg+xml")
    refute media.valid?
    assert media.errors[:file].present?
  end

  test "accepts a valid image" do
    media = Events::EventMedia.new(event: @event, created_by: @user, type: "gallery", position: 1)
    attach_image(media)
    assert media.valid?, media.errors.full_messages.inspect
  end

  test "allows only one cover per event" do
    Events::EventMedia.create!(
      event: @event, created_by: @user, type: "cover", position: 0
    ) do |media|
      attach_image(media)
    end
    second = Events::EventMedia.new(event: @event, created_by: @user, type: "cover", position: 0)
    refute second.valid?
    assert second.errors[:type].present?
  end

  test "caps gallery images at twenty per event" do
    Prosopite.finish if ENV["N_PLUS_ONE"] == "1"
    20.times do |i|
      Events::EventMedia.create!(event: @event, created_by: @user, type: "gallery", position: i) do |media|
        attach_image(media)
      end
    end
    Prosopite.scan if ENV["N_PLUS_ONE"] == "1"
    twenty_first = Events::EventMedia.new(
      event: @event, created_by: @user, type: "gallery", position: 21
    )
    refute twenty_first.valid?
    assert twenty_first.errors[:base].present?
  end

  test "created_by is required" do
    media = Events::EventMedia.new(event: @event, type: "gallery", position: 1)
    refute media.valid?
    assert media.errors[:created_by].present?
  end
end
