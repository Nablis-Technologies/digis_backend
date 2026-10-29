# frozen_string_literal: true

require "set"
require "stringio"
require "test_helper"

module Messaging
  class ImportCampaignContactListJobTest < ActiveJob::TestCase
    include ActiveJob::TestHelper

    test "enqueues only the import id" do
      list = CampaignContactList.create!(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Queue test #{SecureRandom.hex(4)}"
      )
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("phone_number\n+251911123456\n"),
        filename: "contacts.csv",
        content_type: "text/csv"
      )

      assert_enqueued_with(job: Messaging::ImportCampaignContactListJob) do
        result = Messaging::Campaigns::ContactLists::Import.call(
          list:, blob:, actor: core_users(:super_admin), idempotency_key: "queue-test"
        )
        assert result.success?
      end

      job = enqueued_jobs.last
      assert_equal [ result_id_from(job) ], job[:args]
    end

    test "keeps phone and email digest namespaces separate when checking duplicates" do
      job = Messaging::ImportCampaignContactListJob.new
      seen = { phone: Set.new([ "phone-digest" ]), email: Set.new([ "email-digest" ]) }

      refute job.send(:duplicate?, { phone_digest: "email-digest", email_digest: "phone-digest" }, seen)
      assert job.send(:duplicate?, { phone_digest: "phone-digest", email_digest: nil }, seen)
      assert job.send(:duplicate?, { phone_digest: nil, email_digest: "email-digest" }, seen)
    end

    private

    def result_id_from(job)
      job[:args].first
    end
  end
end
