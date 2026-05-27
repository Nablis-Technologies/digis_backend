require "erb"

module Core
  module PolicyMatrixTest
    extend ActiveSupport::Concern

    class_methods do
      def policy_matrix_test(policy_class, **options)
        @policy_class = policy_class
        @model_class = options[:model_class] || resolve_model_class(policy_class)
        @parent_fixture_key = options[:parent_fixture]
        @actions = options[:actions] || %i[index show create update destroy]
        @scope_enabled = options[:scope] || false
        @scope_expectations = options[:scope_expectations] || {}

        fixture_data = load_fixture_data
        @users = options[:users] || fixture_data.keys

        _parent_fixture_accessor = resolve_parent_fixture_accessor
        _parent_fixture_key = @parent_fixture_key
        _child_assoc = child_association
        _model_class = @model_class
        _policy_class = @policy_class

        if _parent_fixture_accessor
          setup do
            @parent = public_send(_parent_fixture_accessor, _parent_fixture_key)
            @saved_child = @parent.public_send(_child_assoc).first
            @saved_child ||= @parent.public_send(_child_assoc).create!(compute_minimal_saved_attrs(_model_class))
          end
        end

        @users.each do |fixture_key|
          data = fixture_data[fixture_key]
          next unless data

          mock_user = MockUser.new(role_codes: data[:role_codes], perm_codes: data[:perm_codes])
          record = @model_class.new

          @actions.each do |action|
            expected = @policy_class.new(mock_user, record).public_send("#{action}?") rescue false
            label = expected ? "permits" : "denies"

            test "#{action}? #{label} #{fixture_key}" do
              user = core_users(fixture_key)
              rec = resolve_record_for(action, _model_class, _child_assoc)
              result = _policy_class.new(user, rec).public_send("#{action}?")
              expected ? assert(result) : assert_not(result)
            end
          end
        end

        if @scope_enabled && @scope_expectations.any?
          _scope_class = _policy_class.const_get(:Scope)
          _scope_model = _model_class
          mc = @model_class

          scope_record_method = define_method(:scope_record) do
            @saved_child || mc.first
          end

          @scope_expectations.each do |fixture_key, expectation|
            test "scope #{expectation} record for #{fixture_key}" do
              user = core_users(fixture_key)
              scope = _scope_class.new(user, _scope_model)
              if expectation == :includes
                assert_includes scope.resolve, scope_record
              else
                refute_includes scope.resolve, scope_record
              end
            end
          end
        end
      end

      private

      def resolve_model_class(policy_class)
        policy_class.name.sub(/Policy$/, "").constantize
      end

      def resolve_parent_fixture_accessor
        return nil unless @parent_fixture_key

        non_user_parent = @model_class.reflect_on_all_associations(:belongs_to)
          .reject { |a| a.klass == Core::User }
          .first

        non_user_parent&.klass&.model_name&.route_key
      end

      def child_association
        if respond_to?(:controller_class) && controller_class&.respond_to?(:parent_association)
          controller_class.parent_association
        else
          route_key = @model_class.model_name.route_key
          short = route_key.sub(/^#{@model_class.module_parent.name.underscore}_/, "")
          short.to_sym
        end
      end

      def load_fixture_data
        base = Rails.root.join("test/fixtures")

        users = load_yaml_with_erb(base.join("core_users.yml"))
          .select { |_, v| v.is_a?(Hash) }

        roles = load_yaml_with_erb(base.join("core_roles.yml"))
          .select { |_, v| v.is_a?(Hash) }
          .to_h { |_, v| [ v["id"], v["code"] ] }

        user_roles = load_yaml_with_erb(base.join("core_user_roles.yml"))
          .select { |_, v| v.is_a?(Hash) }

        role_permissions = load_yaml_with_erb(base.join("core_role_permissions.yml"))
          .select { |_, v| v.is_a?(Hash) }

        permissions = load_yaml_with_erb(base.join("core_permissions.yml"))
          .select { |_, v| v.is_a?(Hash) }
          .to_h { |_, v| [ v["id"], v["code"] ] }

        users.map do |key, attrs|
          user_id = attrs["id"]
          role_ids = user_roles
            .select { |_, ur| ur["user_id"] == user_id }
            .map { |_, ur| ur["role_id"] }
          role_codes = role_ids.map { |rid| roles[rid] }.compact
          perm_ids = role_permissions
            .select { |_, rp| role_ids.include?(rp["role_id"]) }
            .map { |_, rp| rp["permission_id"] }
          perm_codes = perm_ids.map { |pid| permissions[pid] }.compact

          [ key.to_sym, { role_codes: role_codes, perm_codes: perm_codes } ]
        end.to_h
      end

      def load_yaml_with_erb(path)
        raw = File.read(path)
        yaml = raw.include?("<%") ? ERB.new(raw, trim_mode: "-").result(binding) : raw
        YAML.safe_load(yaml)
      end

      MockUser = Struct.new(:role_codes, :perm_codes, keyword_init: true) do
        def has_role?(code)
          role_codes.include?(code)
        end

        def has_permission?(code)
          role_codes.include?("SUPER_ADMIN") || perm_codes.include?(code)
        end

        def super_admin?
          role_codes.include?("SUPER_ADMIN")
        end
      end
    end

    private

    def resolve_record_for(action, model_class, child_assoc)
      case action
      when :index, :create then model_class.new
      when :show, :update, :destroy then model_class.new
      end
    end

    def compute_minimal_saved_attrs(model_class)
      attrs = {}

      model_class.defined_enums.each do |col, mapping|
        attrs[col] = mapping.keys.find { |k| k != "owner" } || mapping.keys.first
      end

      model_class.reflect_on_all_associations(:belongs_to).each do |ref|
        next if ref.polymorphic?
        next if ref == non_user_parent_association(model_class)

        if ref.klass == Core::User
          attrs[ref.foreign_key] = non_owner_user.id
        end
      end

      attrs
    end

    def non_owner_user
      core_users(:attendee)
    end

    def non_user_parent_association(model_class)
      model_class.reflect_on_all_associations(:belongs_to)
        .reject { |a| a.klass == Core::User }
        .first
    end
  end
end
