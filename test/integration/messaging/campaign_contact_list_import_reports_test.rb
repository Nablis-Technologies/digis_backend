# frozen_string_literal: true

require "stringio"
require "test_helper"

module Messaging
  class CampaignContactListImportReportsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    test "authorized organizers can download a sanitized rejected-row report" do
      organization = organizations_organizations(:two)
      actor = core_users(:super_admin)
      list = CampaignContactList.create!(
        organization:, created_by: actor, name: "Report #{SecureRandom.hex(4)}"
      )
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("phone_number,email\n,not-an-email\n"),
        filename: "report.csv", content_type: "text/csv"
      )
      import = Campaigns::ContactLists::Import.call(
        list:, blob:, actor:, idempotency_key: "report-import-#{SecureRandom.hex(4)}"
      ).value
      ImportCampaignContactListJob.perform_now(import.id)

      get "/organizations/#{organization.id}/campaign_contact_lists/#{list.id}/imports/#{import.id}/report",
        headers: admin_headers

      assert_response :success
      assert_equal "text/csv", response.media_type
      assert_includes response.body, "email_invalid"
    end
  end
end
