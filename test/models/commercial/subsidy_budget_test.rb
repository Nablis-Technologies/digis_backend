# frozen_string_literal: true

require "test_helper"

module Commercial
  class SubsidyBudgetTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @organization = organizations_organizations(:two)
      @schedule = create_schedule(code: "budget_#{SecureRandom.hex(5)}")
      @version = create_version(@schedule)
      @component = create_subsidy_component(@version)
      @assignment = create_assignment(@version)
    end

    test "requires exactly one assignment or program owner" do
      missing_owner = build_budget(assignment: nil)
      both_owners = build_budget(program: create_program)

      assert_not missing_owner.valid?
      assert_not both_owners.valid?
      assert missing_owner.errors.key?(:base)
      assert both_owners.errors.key?(:base)
    end

    test "accepts an assignment-owned budget aligned to its fee version" do
      budget = build_budget

      assert_predicate budget, :valid?
      assert_equal "ETB", budget.currency
      assert_equal 1_000, budget.remaining_minor
    end

    test "accepts a program-owned budget aligned to the program fee schedule" do
      program_schedule = create_schedule(
        code: "program_budget_#{SecureRandom.hex(5)}",
        schedule_type: "program"
      )
      program_version = create_version(program_schedule)
      program_component = create_subsidy_component(program_version)
      program = create_program(program_schedule)

      budget = build_budget(assignment: nil, program:, fee_component: program_component)

      assert_predicate budget, :valid?
    end

    test "requires a platform subsidy component" do
      regular_component = create_component(@version)
      budget = build_budget(fee_component: regular_component)

      assert_not budget.valid?
      assert budget.errors.key?(:fee_component)
    end

    test "requires the owner and component to use the same fee version" do
      other_version = create_version(create_schedule(code: "other_budget_#{SecureRandom.hex(5)}"))
      other_assignment = create_assignment(other_version)
      budget = build_budget(assignment: other_assignment)

      assert_not budget.valid?
      assert budget.errors.key?(:fee_component)
    end

    test "requires a supported component currency" do
      currency_component = create_subsidy_component(@version, currency: "USD")
      invalid = build_budget(fee_component: currency_component, currency: "ETB")
      valid = build_budget(fee_component: currency_component, currency: "USD")

      assert_not invalid.valid?
      assert invalid.errors.key?(:currency)
      assert_predicate valid, :valid?
    end

    test "matches a fee amount currency when the component has explicit amounts" do
      create_amount(@component, currency: "USD")
      invalid = build_budget(currency: "ETB")
      valid = build_budget(currency: "USD")

      assert_not invalid.valid?
      assert invalid.errors.key?(:currency)
      assert_predicate valid, :valid?
    end

    test "normalizes currency and validates budget counters" do
      budget = build_budget(currency: " usd ", limit_minor: 100, reserved_minor: 60, consumed_minor: 40)
      invalid = build_budget(limit_minor: 0, reserved_minor: -1, consumed_minor: -1, lock_version: -1)

      assert_predicate budget, :valid?
      assert_equal "USD", budget.currency
      assert_not invalid.valid?
      assert invalid.errors.key?(:limit_minor)
      assert invalid.errors.key?(:reserved_minor)
      assert invalid.errors.key?(:consumed_minor)
      assert invalid.errors.key?(:lock_version)
    end

    test "rejects counters that exceed the hard limit" do
      budget = build_budget(limit_minor: 100, reserved_minor: 60, consumed_minor: 41)

      assert_not budget.valid?
      assert budget.errors.key?(:base)
    end

    test "database enforces budget invariants" do
      assert_database_rejects(assignment_id: nil, program_id: nil)
      assert_database_rejects(assignment_id: @assignment.id, program_id: create_program.id)
      assert_database_rejects(limit_minor: 0)
      assert_database_rejects(reserved_minor: -1)
      assert_database_rejects(consumed_minor: -1)
      assert_database_rejects(limit_minor: 100, reserved_minor: 60, consumed_minor: 41)
      assert_database_rejects(currency: "usd")
      assert_database_rejects(assignment_id: SecureRandom.uuid)
      assert_database_rejects(fee_component_id: SecureRandom.uuid)
    end

    test "enforces one budget per owner, component, and currency" do
      first = build_budget
      first.save!
      duplicate = build_budget

      assert_not duplicate.valid?
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }

      program_schedule = create_schedule(
        code: "duplicate_program_#{SecureRandom.hex(5)}",
        schedule_type: "program"
      )
      program_version = create_version(program_schedule)
      program_component = create_subsidy_component(program_version)
      program = create_program(program_schedule)
      first_program_budget = build_budget(
        assignment: nil,
        program:,
        fee_component: program_component
      )
      first_program_budget.save!
      duplicate_program_budget = build_budget(
        assignment: nil,
        program:,
        fee_component: program_component
      )

      assert_not duplicate_program_budget.valid?
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate_program_budget.save!(validate: false) }
    end

    test "exposes safe query contracts and associations" do
      assert_equal "Commercial::Assignment", SubsidyBudget.reflect_on_association(:assignment).class_name
      assert_equal "Commercial::Program", SubsidyBudget.reflect_on_association(:program).class_name
      assert_equal "Commercial::FeeComponent", SubsidyBudget.reflect_on_association(:fee_component).class_name
      assert_includes SubsidyBudget.ransackable_attributes, "limit_minor"
      assert_includes SubsidyBudget.ransackable_associations, "fee_component"
    end

    test "validates persisted budgets without lazy-loading associations" do
      budget = build_budget
      budget.save!
      fetched = SubsidyBudget.strict_loading.find(budget.id)

      assert_predicate fetched, :valid?
    end

    private

    def create_subsidy_component(version, currency: nil)
      create_component(
        version,
        component_type: "platform_subsidy",
        calculation_type: "percentage",
        charged_to: "buyer",
        funded_by: "platform",
        basis_type: "eligible_order_subtotal",
        rate_bps: 1_000,
        offset_component_type: "buyer_service_fee",
        currency:,
        label: "Platform subsidy"
      )
    end

    def create_assignment(version)
      Commercial::Assignment.create!(
        organization: @organization,
        fee_schedule_version: version,
        assignment_type: "mutual_agreement",
        status: "draft",
        reason: "Subsidy budget test agreement",
        effective_from: 1.day.ago,
        risk_level: "low",
        created_by: core_users(:super_admin)
      )
    end

    def create_program(schedule = create_schedule(code: "owner_program_#{SecureRandom.hex(5)}", schedule_type: "program"))
      Commercial::Program.create!(
        fee_schedule: schedule,
        program_type: "charity",
        enrollment_mode: "manual",
        active: true
      )
    end

    def build_budget(assignment: @assignment, program: nil, fee_component: @component,
      currency: "ETB", limit_minor: 1_000, reserved_minor: 0, consumed_minor: 0, lock_version: 0)
      SubsidyBudget.new(
        assignment:,
        program:,
        fee_component:,
        currency:,
        limit_minor:,
        reserved_minor:,
        consumed_minor:,
        lock_version:
      )
    end

    def assert_database_rejects(attributes)
      database_attributes = {
        assignment_id: @assignment.id,
        program_id: nil,
        fee_component_id: @component.id,
        currency: "ETB",
        limit_minor: 1_000,
        reserved_minor: 0,
        consumed_minor: 0,
        lock_version: 0
      }.merge(attributes)

      assert_raises(ActiveRecord::StatementInvalid) do
        SubsidyBudget.transaction(requires_new: true) do
          SubsidyBudget.new(database_attributes).save!(validate: false)
        end
      end
    end
  end
end
