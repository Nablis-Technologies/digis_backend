# frozen_string_literal: true

require "test_helper"

module Legal
  class LegalDocumentPolicyTest < ActiveSupport::TestCase
    test "only super_admin can publish" do
      doc = Legal::LegalDocument.new
      assert Admin::LegalDocumentPolicy.new(core_users(:super_admin), doc).publish?
      assert_not Admin::LegalDocumentPolicy.new(core_users(:attendee), doc).publish?
    end
  end
end
