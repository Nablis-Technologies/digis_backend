# frozen_string_literal: true

require "test_helper"

class PublicEventCatalogPerformanceTest < ActionDispatch::IntegrationTest
  include PerformanceQueryHelpers

  setup do
    @event = events_events(:ready_listing)
    @event.update!(status: "published", visibility: "public")
    without_n_plus_one do
      make_publishable(@event)
      add_gallery_media(@event, count: 3)
    end
  end

  test "public event index query count stays bounded as the result set grows" do
    baseline = count_database_queries { get "/public/events", as: :json }
    assert_response :success
    assert_operator baseline, :<=, 12, "public event list used #{baseline} queries"

    4.times { |index| create_public_event(index) }
    expanded = count_database_queries { get "/public/events", as: :json }
    assert_response :success

    assert_operator expanded, :<=, baseline + 2,
                    "public event list grew from #{baseline} to #{expanded} queries"
  end

  test "public event detail stays within the nested catalog query budget" do
    queries = count_database_queries { get "/public/events/#{@event.slug}", as: :json }

    assert_response :success
    assert_operator queries, :<=, 16, "public event detail used #{queries} queries"
  end

  private

  def without_n_plus_one
    defined?(Prosopite) ? Prosopite.pause { yield } : yield
  end

  def add_gallery_media(event, count:)
    count.times do |index|
      media = event.event_media.build(created_by: core_users(:super_admin), type: "gallery", position: index + 1,
                                      alt_text: "Gallery image #{index + 1}")
      media.file.attach(
        io: StringIO.new(File.binread(Rails.root.join("test/fixtures/files/pixel.png"))),
        filename: "gallery-#{index + 1}.png", content_type: "image/png"
      )
      media.save!
    end
  end

  def create_public_event(index)
    Events::Event.create!(
      organization: @event.organization,
      created_by: core_users(:super_admin),
      title: "Public event #{index}",
      slug: "public-event-#{index}-#{SecureRandom.hex(3)}",
      status: "published",
      visibility: "public",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB"
    )
  end
end
