# frozen_string_literal: true

require "csv"
require "stringio"
require "test_helper"

module Messaging
  module Campaigns
    module ContactLists
      class ImportTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @list = CampaignContactList.create!(
            organization: organizations_organizations(:one),
            created_by: core_users(:super_admin),
            name: "Import test #{SecureRandom.hex(4)}"
          )
          @actor = core_users(:super_admin)
        end

        test "rejects an import over the file-size limit" do
          blob = ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new("x" * (5.megabytes + 1)),
            filename: "contacts.csv",
            content_type: "text/csv"
          )

          result = Import.call(list: @list, blob:, actor: @actor, idempotency_key: "import-size")

          assert result.failure?
          assert_equal "contact_list_file_too_large", result.error.code
        end

        test "rejects an import over the row limit in the asynchronous job" do
          blob = csv_blob(rows: 3)
          result = Import.call(list: @list, blob:, actor: @actor, idempotency_key: "import-rows")

          assert result.success?
          import = result.value
          with_row_limit(2) { ImportCampaignContactListJob.perform_now(import.id) }

          assert_equal "failed", import.reload.status
          assert_equal "contact_list_row_limit_exceeded", import.error_detail
        end

        test "imports valid contacts and produces a sanitized rejected report" do
          blob = ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new("phone_number,email,first_name\n+251911123456,valid@example.com,User\n,not-an-email,=SUM(1+1)\n"),
            filename: "contacts.csv",
            content_type: "text/csv"
          )
          import = Import.call(list: @list, blob:, actor: @actor, idempotency_key: "import-report").value

          ImportCampaignContactListJob.perform_now(import.id)

          import.reload
          assert_equal "completed", import.status
          assert_equal 1, import.accepted_rows
          assert import.rejected_report.attached?
          assert_includes import.rejected_report.download, "'=SUM(1+1)"
        end

        test "flushes accepted contacts through a batch insert" do
          blob = ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new("phone_number,email\n+251911123456,one@example.com\n+251911123457,two@example.com\n"),
            filename: "contacts.csv", content_type: "text/csv"
          )
          import = Import.call(list: @list, blob:, actor: @actor, idempotency_key: "import-batch").value
          CampaignContactListEntry.expects(:insert_all).with do |rows|
            rows.size == 2 && rows.all? { |row| row["campaign_contact_list_id"] == @list.id }
          end.returns([])

          ImportCampaignContactListJob.perform_now(import.id)
        end

        test "append is idempotent and replace requires confirmation" do
          row = { phone_number: "+251911123456", first_name: "A" }
          append = -> { Append.call(list: @list, rows: [ row ], actor: @actor, idempotency_key: "append-1") }

          assert_idempotent(append, counter: -> { @list.entries.count })
          assert_equal 1, @list.reload.entries.count

          without_confirmation = Replace.call(
            list: @list, rows: [ { email: "new@example.com" } ], actor: @actor,
            confirm: false, idempotency_key: "replace-1"
          )
          assert_equal "contact_list_replace_confirmation_required", without_confirmation.error.code

          replaced = Replace.call(
            list: @list, rows: [ { email: "new@example.com" } ], actor: @actor,
            confirm: true, idempotency_key: "replace-2"
          )
          assert replaced.success?
          assert_equal [ "new@example.com" ], @list.reload.entries.map(&:email)
        end

        test "replace skips duplicate addresses in the submitted rows" do
          row = { phone_number: "+251911123456", first_name: "A" }

          result = Replace.call(
            list: @list, rows: [ row, row ], actor: @actor, confirm: true, idempotency_key: "replace-duplicates"
          )

          assert result.success?, result.error&.message
          assert_equal 1, @list.reload.entries.where(status: "active").count
        end

        private

        def with_row_limit(limit)
          original = ImportCampaignContactListJob::MAX_ROWS
          silence_warnings { ImportCampaignContactListJob.const_set(:MAX_ROWS, limit) }
          yield
        ensure
          silence_warnings { ImportCampaignContactListJob.const_set(:MAX_ROWS, original) }
        end

        def csv_blob(rows:)
          csv = CSV.generate do |output|
            output << %w[phone_number email first_name]
            rows.times { |index| output << [ "+2519#{format("%08d", index)}", nil, "User #{index}" ] }
          end
          ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new(csv), filename: "contacts.csv", content_type: "text/csv"
          )
        end
      end
    end
  end
end
