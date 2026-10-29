# frozen_string_literal: true

require "test_helper"

module Security
  class PrivateMediaTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::AttendeeExportTestHelpers

    setup do
      @organization = organizations_organizations(:one)
      @event = events_events(:ready_listing)
      @export = create_export(event: @event, actor: core_users(:super_admin))
      @export.file.attach(
        io: StringIO.new("private export"), filename: "attendees.csv", content_type: "text/csv"
      )
    end

    test "organization verification documents require authentication and a short-lived delivery endpoint" do
      @organization.business_license.attach(
        io: StringIO.new("license"), filename: "license.pdf", content_type: "application/pdf"
      )

      get "/organizations/owner/#{@organization.id}/documents/business_license", as: :json
      assert_response :unauthorized

      get "/organizations/owner/#{@organization.id}/documents/business_license",
          headers: admin_headers, as: :json
      assert_response :redirect
      assert_includes response.location, "/rails/active_storage/blobs/redirect/"
    end

    test "platform-admin verification document delivery is separately authorized" do
      @organization.tin_certificate.attach(
        io: StringIO.new("tin"), filename: "tin.pdf", content_type: "application/pdf"
      )

      get "/admin/organizations/#{@organization.id}/documents/tin_certificate", as: :json
      assert_response :unauthorized

      get "/admin/organizations/#{@organization.id}/documents/tin_certificate",
          headers: admin_headers, as: :json
      assert_response :redirect
      assert_includes response.location, "/rails/active_storage/blobs/redirect/"
    end

    test "private attendee exports use the private storage service and never expose a direct URL" do
      assert_equal "private_exports", @export.file.blob.service_name

      get "/attendee_exports/#{@export.id}", as: :json
      assert_response :unauthorized

      get "/attendee_exports/#{@export.id}", headers: admin_headers, as: :json
      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_not data.key?("url")
      assert_not data.key?("download_url")
    end

    test "encrypted invitation delivery values are not readable through raw SQL" do
      ticket_type = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Private invitation #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "invitation", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
      result = Ticketing::Invitations::Create.call(
        ticket_type:,
        actor: core_users(:super_admin),
        attributes: { email: "private-guest@example.com", allowed_quantity: 1 },
        idempotency_key: "private-media-invitation"
      )

      assert_predicate result, :success?, result.error&.message
      invitation = result.value.record
      rows = Ticketing::Invitation.connection.select_one(
        "SELECT email_ciphertext, token_ciphertext FROM ticketing_invitations WHERE id = '#{invitation.id}'"
      )

      refute_includes rows.fetch("email_ciphertext"), "private-guest@example.com"
      refute_includes rows.fetch("token_ciphertext"), result.value.token
    end
  end
end
