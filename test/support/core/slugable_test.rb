module Core
  module SlugableTest
    extend ActiveSupport::Concern

    class_methods do
      def test_slugable(create_params: nil)
        model_class = _resolve_model
        source_col = model_class._slug_source
        target_col = model_class._slug_target

        test "generates slug from #{source_col} automatically" do
          params = resolve_params(create_params, source_col)
          record = model_class.create!(params)
          assert_equal params[source_col].to_s.parameterize, record.public_send(target_col)
        end

        test "handles duplicate slugs with counter" do
          params = resolve_params(create_params, source_col)
          model_class.create!(params)
          duplicate_params = params.deep_dup
          duplicate_params[source_col] = "#{params[source_col]} "
          duplicate = model_class.create!(duplicate_params)
          assert_equal "#{params[source_col].to_s.parameterize}-1", duplicate.public_send(target_col)
        end

        test "updates slug when #{source_col} changes" do
          params = resolve_params(create_params, source_col)
          record = model_class.create!(params)
          new_value = "#{params[source_col]}-updated"
          record.update!(source_col => new_value)
          assert_equal new_value.to_s.parameterize, record.public_send(target_col)
        end
      end

      private

      def _resolve_model
        name.delete_suffix("Test").safe_constantize ||
          name.underscore.delete_suffix("_test").split("_").map(&:camelize).join("::").safe_constantize
      end
    end

    private

    def resolve_params(create_params, source_col)
      if create_params
        instance_exec(&create_params)
      else
        { source_col => "Test" }
      end
    end
  end
end
