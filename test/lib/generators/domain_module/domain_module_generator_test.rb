# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/domain_module/domain_module_generator"

class DomainModuleGeneratorDefaultTest < Rails::Generators::TestCase
  tests DomainModuleGenerator

  # Each test class gets its own isolated destination so parallel workers and
  # sibling generator tests never race in prepare_destination (a shared tmp
  # path previously hung/failed the parallel suite).
  destination File.expand_path("../../../../tmp/domain_module_generator/default_#{Process.pid}", __dir__)
  setup :prepare_destination

  test "generates model without inheritance_column by default" do
    run_generator %w[Catalog::Product name:string --no-interactive --no-business-type --skip-tests --skip-routes]

    assert_file "app/models/catalog/product.rb" do |content|
      assert_no_match(/self\.inheritance_column = nil/, content)
    end
  end
end

class DomainModuleGeneratorBusinessTypeTest < Rails::Generators::TestCase
  tests DomainModuleGenerator

  destination File.expand_path("../../../../tmp/domain_module_generator/business_type_#{Process.pid}", __dir__)
  setup :prepare_destination

  test "generates model with inheritance_column when --business-type is set" do
    run_generator %w[Catalog::Widget name:string --no-interactive --business-type --skip-tests --skip-routes]

    assert_file "app/models/catalog/widget.rb" do |content|
      assert_match(/self\.inheritance_column = nil/, content)
    end
  end
end
