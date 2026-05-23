module Core
  module SlugableTest
    extend ActiveSupport::Concern

    class_methods do
      def test_slugable(create_params:)
        model_class = name.delete_suffix("Test").safe_constantize
        source_col = model_class._slug_source
        target_col = model_class._slug_target

        test "generates slug from #{source_col} automatically" do
          params = instance_exec(&create_params)
          record = model_class.create!(params)
          assert_equal params[source_col].to_s.parameterize, record.public_send(target_col)
        end

        test "handles duplicate slugs with counter" do
          params = instance_exec(&create_params)
          model_class.create!(params)
          duplicate = model_class.create!(params)
          base_slug = params[source_col].to_s.parameterize
          assert_equal "#{base_slug}-1", duplicate.public_send(target_col)
        end

        test "updates slug when #{source_col} changes" do
          params = instance_exec(&create_params)
          record = model_class.create!(params)
          new_source = "#{params[source_col]}-updated"
          record.update!(source_col => new_source)
          assert_equal new_source.to_s.parameterize, record.public_send(target_col)
        end
      end
    end
  end
end
