# frozen_string_literal: true

require "test_helper"

module Messaging
  class CampaignContactListTest < ActiveSupport::TestCase
    setup do
      @list = CampaignContactList.create!(
        organization: organizations_organizations(:one),
        created_by: core_users(:super_admin),
        name: "Test contacts"
      )
    end

    test "requires at least one channel address" do
      entry = @list.entries.build

      refute entry.valid?
      assert entry.errors.details[:base].any? { |detail| detail[:error] == :contact_required }
    end

    test "encrypts contact values while preserving normalized digests" do
      entry = @list.entries.create!(
        phone_number: "+251911123456",
        phone_digest: "a" * 64,
        source: "manual"
      )

      assert_equal "+251911123456", entry.phone_number
      refute_equal "+251911123456", entry.attributes_before_type_cast.fetch("phone_number_ciphertext")
      assert_equal "a" * 64, entry.phone_digest
    end
  end
end
