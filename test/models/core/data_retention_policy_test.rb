# frozen_string_literal: true

require "test_helper"

module Core
  class DataRetentionPolicyTest < ActiveSupport::TestCase
    test "requires a retention period when the action erases payloads" do
      policy = DataRetentionPolicy.new(
        category: "registration_free_text",
        version: 1,
        action: "erase_payload",
        status: "draft",
        created_by: core_users(:super_admin)
      )

      assert_not policy.valid?
      assert policy.errors.key?(:retention_days)
    end

    test "normalizes jurisdiction codes for null-safe policy scopes" do
      policy = DataRetentionPolicy.new(
        category: "registration_free_text",
        jurisdiction_code: " et ",
        version: 1,
        action: "retain",
        status: "draft",
        created_by: core_users(:super_admin)
      )

      policy.valid?

      assert_equal "ET", policy.jurisdiction_code
    end

    test "rejects duplicate policy versions when jurisdiction is null" do
      DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        action: "retain",
        status: "draft",
        created_by: core_users(:super_admin)
      )
      duplicate = DataRetentionPolicy.new(
        category: "registration_free_text",
        version: 1,
        action: "retain",
        status: "draft",
        created_by: core_users(:super_admin)
      )

      assert_not duplicate.valid?
      assert duplicate.errors.key?(:version)
    end

    test "rejects a second active policy for the same category and jurisdiction" do
      DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      duplicate = DataRetentionPolicy.new(
        category: "registration_free_text",
        jurisdiction_code: nil,
        version: 2,
        retention_days: 60,
        action: "erase_payload",
        status: "active",
        effective_at: 1.hour.ago,
        created_by: core_users(:super_admin)
      )

      assert_not duplicate.valid?
      assert duplicate.errors.key?(:status)
    end

    test "active policy payload cannot be changed through bulk updates" do
      policy = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        DataRetentionPolicy.transaction(requires_new: true) do
          DataRetentionPolicy.where(id: policy.id).update_all(retention_days: 60)
        end
      end
    end

    test "retired policy payload cannot be changed through bulk updates" do
      policy = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      policy.update!(status: "retired")

      assert_raises(ActiveRecord::StatementInvalid) do
        DataRetentionPolicy.transaction(requires_new: true) do
          DataRetentionPolicy.where(id: policy.id).update_all(retention_days: 60)
        end
      end
    end

    test "retiring a policy does not violate version monotonicity" do
      policy = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 2,
        retention_days: 60,
        action: "erase_payload",
        status: "draft",
        created_by: core_users(:super_admin)
      )

      policy.status = "retired"

      assert_predicate policy, :valid?
    end

    test "cannot activate an older draft after a newer version retires" do
      older = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "draft",
        created_by: core_users(:super_admin)
      )
      newer = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 2,
        retention_days: 60,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      newer.update!(status: "retired")

      older.status = "active"
      assert_not older.valid?
      assert older.errors.key?(:version)
      assert_raises(ActiveRecord::StatementInvalid) do
        DataRetentionPolicy.where(id: older.id).update_all(status: "active")
      end
    end

    test "database rejects an older active policy inserted after a newer version retires" do
      newer = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 2,
        retention_days: 60,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      newer.update!(status: "retired")

      assert_raises(ActiveRecord::StatementInvalid) do
        DataRetentionPolicy.transaction(requires_new: true) do
          DataRetentionPolicy.insert_all!([
            {
              id: SecureRandom.uuid,
              category: "registration_free_text",
              version: 1,
              retention_days: 30,
              action: "erase_payload",
              status: "active",
              effective_at: 1.day.ago,
              created_by_id: core_users(:super_admin).id,
              created_at: Time.current,
              updated_at: Time.current
            }
          ])
        end
      end
    end

    test "does not invalidate an active policy because a newer draft exists" do
      active = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )
      DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 2,
        retention_days: 60,
        action: "erase_payload",
        status: "draft",
        created_by: core_users(:super_admin)
      )

      assert_predicate active.reload, :valid?
    end

    test "does not allow an active policy to return to draft" do
      policy = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )

      policy.status = "draft"

      assert_not policy.valid?
      assert policy.errors.key?(:status)
    end

    test "does not allow active or retired policy payloads to change" do
      policy = DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.ago,
        created_by: core_users(:super_admin)
      )

      policy.retention_days = 60

      assert_not policy.valid?
      assert policy.errors.key?(:base)

      policy.reload
      policy.update!(status: "retired")
      policy.retention_days = 90

      assert_not policy.valid?
      assert policy.errors.key?(:base)
    end
  end
end
