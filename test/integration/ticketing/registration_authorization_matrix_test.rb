# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationAuthorizationMatrixTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::AttendeeExportTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @ticket_type = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Authorization matrix ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
      @registration = Ticketing::Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: core_users(:attendee),
        created_by: core_users(:attendee),
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      RegistrationForm.create!(event: @event, name: "Authorization matrix form", active: true)
      @export = create_export(event: @event, actor: core_users(:super_admin))
    end

    test "applies distinct authorization boundaries to attendee, organizer, support, and export surfaces" do
      get "/registrations/#{@registration.id}", headers: user_headers, as: :json
      assert_response :success

      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )
      support_headers = { "Authorization" => "Bearer #{support_token}" }

      get "/registrations/#{@registration.id}", headers: support_headers, as: :json
      assert_response :forbidden

      get "/events/#{@event.id}/registration_forms", headers: owner_headers, as: :json
      assert_response :success

      get "/events/#{@event.id}/registration_forms", headers: user_headers, as: :json
      assert_response :forbidden

      get "/attendee_exports/#{@export.id}", headers: support_headers, as: :json
      assert_response :forbidden
    end
  end
end
