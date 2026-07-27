# frozen_string_literal: true

require "test_helper"

class EventsPhaseAcceptanceTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  def make_verified(organization)
    Core::Review.create!(
      reviewable: organization,
      context: "verification",
      status: "approved"
    )
  end

  def setup
    @organization = organizations_organizations(:one)
    make_verified(@organization)
    @actor = core_users(:super_admin)
  end

  test "full lifecycle: build, publish, reschedule, and expose boundaries" do
    result = Events::Create.call(
      organization: @organization,
      actor: @actor,
      attributes: { title: "Phase Gate Concert", description: "d", visibility: "public",
                    timezone: "Africa/Addis_Ababa", currency: "ETB" },
      category_ids: [ events_categories(:music).id ]
    )
    assert result.success?, result.error.inspect
    event = result.value
    assert event.persisted?

    make_publishable(event)

    date = event.event_dates.create!(
      starts_at: 2.months.from_now.beginning_of_hour,
      ends_at: 2.months.from_now.beginning_of_hour + 2.hours,
      status: "scheduled"
    )
    date_id = date.id

    recurrence = Events::Recurrence::Configure.call(
      event:, actor: @actor,
      attributes: {
        rrule: "FREQ=WEEKLY;INTERVAL=1;COUNT=4",
        timezone: "Africa/Addis_Ababa",
        dtstart_local: 1.month.from_now.beginning_of_hour,
        duration_seconds: 7200
      }
    )
    assert recurrence.success?, recurrence.error.inspect
    assert recurrence.value.persisted?

    event.event_participants.create!(name: "Headliner", type: "performer", display_order: 1)
    event.access_zones.create!(code: "GA", name: "General Admission", type: "venue", sort_order: 1)

    doc = Events::ConsentDocument.create!(event:, type: "terms", name: "Terms", created_by: @actor)
    doc.versions.create!(
      version: 1, title: "v1", body: "Agree to terms", status: "draft", required: false,
      created_by: @actor,
      content_sha256: Events::ConsentDocumentVersion.content_sha256_for(
        type: "terms", title: "v1", body: "Agree to terms"
      )
    )
    consent = Events::ConsentDocuments::PublishVersion.call(consent_document: doc, actor: @actor)
    assert consent.success?, consent.error.inspect
    assert_equal "published", consent.value.status

    Events::EventStaffAssignment.create!(
      event:, user: core_users(:attendee), organization: @organization,
      role: "manager", status: "active"
    )

    post "/events/#{event.id}/publish",
         headers: admin_headers.merge("Idempotency-Key" => "phase-publish"), as: :json
    assert_response :success
    assert_equal "published", event.reload.status
    assert event.reload.published_at.present?

    assert event.audit_logs.for_action("event.published").exists?
    assert Core::OutboxEvent.where(event_type: "event.published", aggregate_id: event.id).exists?

    change = Events::Schedule::Change.call(
      event:, actor: @actor,
      changes: [ { event_date_id: date_id,
                   new_start_at: date.starts_at + 1.day,
                   new_end_at: date.ends_at + 1.day } ],
      idempotency_key: "phase-reschedule"
    )
    assert change.success?, change.error.inspect
    assert Events::EventDate.exists?(date_id), "date id must remain stable"
    rescheduled = Events::EventDate.find(date_id)
    assert_equal date.starts_at + 1.day, rescheduled.starts_at

    get "/public/events/#{event.reload.slug}", as: :json
    assert_response :success
    pub = JSON.parse(response.body)["data"]
    refute pub.key?("status")
    refute pub.key?("version")

    get "/events/#{event.id}", headers: admin_headers, as: :json
    assert_response :success
    owner = JSON.parse(response.body)["data"]
    assert owner.key?("status")
    assert owner.key?("version")
  end
end
