require "test_helper"

class AdminEventsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  # Event creation needs an owning organization, so it is exercised through the
  # owner surface (EventsController); here we cover the admin read/update/
  # moderate surface. Schedules, media, staff, and consent administration are
  # later tasks.
  resource_test model: Events::Event,
                policy_class: Admin::EventPolicy,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: "/admin/events",
                except: %i[create destroy],
                update_params: ->(record) { { event: { title: "Updated #{record.title}" } } },
                check_attributes: {
                  show: %w[id slug title description status visibility],
                  index: %w[id slug title status visibility]
                }

  test "an admin can force-publish an event" do
    event = events_events(:draft_concert)
    event.organization.reviews.find_or_create_by!(context: "verification", status: "approved")
    # ensure at least one category so readiness passes
    Events::ReplaceCategories.call(event:, category_ids: [ events_categories(:music).id ], actor: core_users(:super_admin))
    make_publishable(event, actor: core_users(:super_admin))

    post "/admin/events/#{event.id}/publish", headers: admin_headers.merge("Idempotency-Key" => "admin-publish-1"), as: :json
    assert_response :success
    assert_equal "published", event.reload.status
    assert_equal "Event published successfully", JSON.parse(response.body)["message"]
  end

  test "an admin can unpublish a published event" do
    event = events_events(:ready_listing)
    event.update!(status: "published", published_at: Time.current)

    post "/admin/events/#{event.id}/unpublish", headers: admin_headers, as: :json
    assert_response :success
    assert_equal "draft", event.reload.status
    assert_nil event.published_at
    assert_equal "Event unpublished successfully", JSON.parse(response.body)["message"]
  end

  test "admin publishing without an Idempotency-Key header returns 400" do
    event = events_events(:draft_concert)
    post "/admin/events/#{event.id}/publish", headers: admin_headers, as: :json
    assert_response :bad_request
    assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
  end
end
