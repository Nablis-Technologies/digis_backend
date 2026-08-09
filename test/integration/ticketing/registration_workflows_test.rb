# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationWorkflowsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @manager = core_users(:super_admin)
      @attendee = core_users(:attendee)
    end

    test "an authorized manager approves a registration through the command endpoint" do
      ticket_type = create_ticket_type(approval_mode: "manual", amount_minor: 1, inventory: { mode: "unlimited" })
      registration = create_registration(ticket_type:, status: "pending_approval")

      post "/registrations/#{registration.id}/approve",
           headers: admin_headers.merge("Idempotency-Key" => "api-approve-1"),
           as: :json

      assert_response :success
      assert_equal "pending_payment", response.parsed_body.dig("data", "status")
      assert_not_nil registration.reload.approved_at
    end

    test "decision endpoints require an idempotency key" do
      ticket_type = create_ticket_type(approval_mode: "manual", amount_minor: 1, inventory: { mode: "unlimited" })
      registration = create_registration(ticket_type:, status: "pending_approval")

      post "/registrations/#{registration.id}/approve", headers: admin_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "an attendee cannot approve another registration" do
      ticket_type = create_ticket_type(approval_mode: "manual", amount_minor: 1, inventory: { mode: "unlimited" })
      registration = create_registration(ticket_type:, status: "pending_approval")

      post "/registrations/#{registration.id}/approve",
           headers: user_headers.merge("Idempotency-Key" => "api-approve-forbidden"),
           as: :json

      assert_response :forbidden
      assert_equal "pending_approval", registration.reload.status
    end

    test "an authorized manager issues a complimentary ticket without financial rows" do
      ticket_type = create_ticket_type(
        approval_mode: "automatic", amount_minor: 100, inventory: { mode: "event_wide", capacity: 2 }
      )

      post "/events/#{@event.id}/complimentary_tickets",
           params: {
             ticket_type_id: ticket_type.id,
             phone: @attendee.phone,
             package_quantity: 1,
             reason: "staff_guest",
             answers: []
           },
           headers: admin_headers.merge("Idempotency-Key" => "api-complimentary-1"),
           as: :json

      assert_response :created
      registration = Registration.find(response.parsed_body.dig("data", "id"))
      assert_equal "confirmed", registration.status
      assert_equal "organizer_complimentary", registration.source
      assert_equal 1, Catalog::ProductInventory.where(event_product: ticket_type.event_product).sum(:sold_count)
    end

    private

    def create_ticket_type(approval_mode:, amount_minor:, inventory:)
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: @manager,
        product_attributes: { name: "Workflow API ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode:, date_selection: "fixed", admissions_per_unit: 1
        },
        price_attributes: { currency: "ETB", amount_minor:, active_from: Time.current },
        inventory_configuration: inventory
      ).value
      assert_predicate Catalog::Products::Activate.call(product:, actor: @manager), :success?
      product.reload.ticket_type
    end

    def create_registration(ticket_type:, status:)
      Registration.create!(
        event: @event,
        ticket_type:,
        user: @attendee,
        created_by: @attendee,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: ticket_type.admissions_per_unit,
        party_size: ticket_type.admissions_per_unit,
        status:,
        submitted_at: Time.current
      )
    end
  end
end
