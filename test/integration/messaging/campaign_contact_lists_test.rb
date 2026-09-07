# frozen_string_literal: true

require "digest"
require "json"
require "tempfile"
require "test_helper"

module Messaging
  class CampaignContactListsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @organization = organizations_organizations(:two)
    end

    test "creates and lists an organizer contact list" do
      headers = admin_headers.merge("Idempotency-Key" => "list-create-1")
      post "/organizations/#{@organization.id}/campaign_contact_lists",
        params: { campaign_contact_list: { name: "Attendees" } }, headers:, as: :json

      assert_response :created
      list_id = JSON.parse(response.body).fetch("data").fetch("id")

      get "/organizations/#{@organization.id}/campaign_contact_lists", headers: admin_headers, as: :json

      assert_response :success
      assert_includes JSON.parse(response.body).fetch("data").map { |list| list.fetch("id") }, list_id
    end

    test "starts an asynchronous CSV import and returns its status" do
      list = CampaignContactList.create!(
        organization: @organization, created_by: core_users(:super_admin),
        name: "Import API #{SecureRandom.hex(4)}"
      )
      file = Tempfile.new([ "contacts", ".csv" ])
      file.write("phone_number\n+251911123456\n")
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "text/csv")

      post "/organizations/#{@organization.id}/campaign_contact_lists/#{list.id}/import",
        params: { file: upload }, headers: admin_headers.merge("Idempotency-Key" => "import-api-1")

      assert_response :accepted
      import_data = JSON.parse(response.body).fetch("data")
      import_id = import_data.fetch("id")
      assert import_data.key?("filename")
      assert import_data.key?("total_rows")
      get "/organizations/#{@organization.id}/campaign_contact_lists/#{list.id}/imports/#{import_id}",
        headers: admin_headers, as: :json
      assert_response :success
      assert_equal "pending", JSON.parse(response.body).fetch("data").fetch("status")
    ensure
      file&.close!
    end

    test "appends contacts from a real JSON request" do
      list = CampaignContactList.create!(
        organization: @organization, created_by: core_users(:super_admin),
        name: "JSON append #{SecureRandom.hex(4)}"
      )

      post "/organizations/#{@organization.id}/campaign_contact_lists/#{list.id}/append",
        params: { rows: [ { phone_number: "+251911123457", first_name: "Aster" } ] },
        headers: admin_headers.merge("Idempotency-Key" => "json-append-#{SecureRandom.hex(4)}"), as: :json

      assert_response :success
      assert_equal 1, list.reload.entries.where(status: "active").count
      assert_equal "Aster", list.entries.first.first_name
    end

    test "removes a contact-list entry and returns its safe serialized state" do
      list = CampaignContactList.create!(
        organization: @organization, created_by: core_users(:super_admin),
        name: "Entry API #{SecureRandom.hex(4)}"
      )
      entry = list.entries.create!(
        phone_number: "+251911123456", phone_digest: Digest::SHA256.hexdigest("entry-api"), status: "active"
      )

      delete "/organizations/#{@organization.id}/campaign_contact_lists/#{list.id}/entries/#{entry.id}",
        headers: admin_headers.merge("Idempotency-Key" => "entry-remove-api"), as: :json

      assert_response :success
      data = JSON.parse(response.body).fetch("data")
      assert_equal entry.id, data.fetch("id")
      assert_equal "removed", data.fetch("status")
      assert_equal true, data.fetch("phone_present")
    end
  end
end
