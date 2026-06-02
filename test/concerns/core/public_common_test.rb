require "test_helper"

class CorePublicCommonTest < ActiveSupport::TestCase
  class TestController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Events::Category
    self.list_serializer = Events::Public::CategoryListSerializer
    self.detail_serializer = Events::Public::CategoryDetailSerializer
  end

  def setup
    @controller = TestController.new
  end

  test "searchable? returns false by default" do
    assert_not @controller.send(:searchable?)
  end

  test "apply_catalog_filters returns scope unchanged by default" do
    scope = Events::Category.all
    assert_equal scope.to_sql, @controller.send(:apply_catalog_filters, scope).to_sql
  end

  test "allowed_order_columns defaults to id and created_at" do
    assert_equal %w[id created_at], @controller.send(:allowed_order_columns)
  end

  test "base_scope delegates to model_class.all" do
    expected = Events::Category.all.to_sql
    assert_equal expected, @controller.send(:base_scope).to_sql
  end

  test "detail_scope delegates to model_class.all" do
    expected = Events::Category.all.to_sql
    assert_equal expected, @controller.send(:detail_scope).to_sql
  end

  test "build_base_scope delegates to base_scope" do
    assert_equal @controller.send(:base_scope).to_sql, @controller.send(:build_base_scope).to_sql
  end

  test "build_detail_scope delegates to detail_scope" do
    assert_equal @controller.send(:detail_scope).to_sql, @controller.send(:build_detail_scope).to_sql
  end

  test "model_class class_attribute works" do
    assert_equal Events::Category, TestController.model_class
  end

  test "list_serializer class_attribute works" do
    assert_equal Events::Public::CategoryListSerializer, TestController.list_serializer
  end

  test "detail_serializer class_attribute works" do
    assert_equal Events::Public::CategoryDetailSerializer, TestController.detail_serializer
  end
end
