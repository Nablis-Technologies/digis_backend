require "erb"

module Core
  module ResourceTest
    extend ActiveSupport::Concern

    included do
      include Core::AuthTestHelpers
      include Core::AuditTestHelpers
      include Core::CrudTestHelpers
      include Core::PaginationTestHelpers
      include Core::PolicyMatrixTest
      include ActiveJob::TestHelper
    end

    class_methods do
      def resource_test(**options)
        meta = Metadata.new(self, options)
        meta.build

        meta.actions.each { |action| generate_tests(action, meta) }
        generate_show_extras(meta)
        generate_index_extras(meta)
        generate_absence_tests(meta)
        generate_destroy_test(meta)

        policy_contract = options.key?(:policy_contract) ? options[:policy_contract] : true
        if policy_contract
          controller_class_value = meta.send(:controller_class)
          singleton_class.define_method(:controller_class) { controller_class_value }
          exclude_actions = Array(options[:except])
          contract_actions = (%i[index show create update destroy] - exclude_actions) & meta.actions
          policy_matrix_test meta.send(:resolve_policy_class),
            model_class: meta.model_class,
            parent_fixture: meta.parent_fixture_key || (meta.send(:parent_class_present?) ? :one : nil),
            actions: contract_actions
        end
      end

      private

      def generate_tests(action, meta)
        unless meta.skip_authorization
          test "#{action} fails for unauthenticated user" do
            perform_request(action, resolve_path_for(meta), record: nil, params: nil, headers: {}, meta: meta)
            assert_response :unauthorized
          end
        end

        meta.fixture_keys.each do |fixture_key|
          expected = meta.policy_results[fixture_key][action]

          test "#{action} #{expected ? :permitted : :forbidden} for #{fixture_key}" do
            user = core_users(fixture_key)
            headers = token_headers_for(user)
            record = resolve_record(action, meta)
            params = resolve_params(action, meta, record)

            perform_request(action, resolve_path_for(meta), record: record, params: params, headers: headers, meta: meta)
            assert_response expected ? :success : :forbidden
          end
        end

        if meta.auditable_actions.include?(action)
          generate_audit_tests(action, meta)
        end
      end

      def generate_audit_tests(action, meta)
        permitted_key = meta.fixture_keys.find { |fk| meta.policy_results[fk][action] }

        if permitted_key
          test "#{action} logs an audit" do
            user = core_users(permitted_key)
            headers = token_headers_for(user)
            record = resolve_record(action, meta)
            params = resolve_params(action, meta, record)

            perform_enqueued_jobs do
              perform_request(action, resolve_path_for(meta), record: record, params: params, headers: headers, meta: meta)
            end

            auditable = if action == :create
              meta.model_class.find(JSON.parse(response.body).dig("data", "id"))
            else
              record
            end

            assert_audit_logged(action: action.to_s, auditable: auditable, actor: user)
          end
        end

        forbidden_key = meta.fixture_keys.reverse.find { |fk| !meta.policy_results[fk][action] }

        if forbidden_key
          test "forbidden #{action} does not enqueue an audit" do
            headers = token_headers_for(core_users(forbidden_key))
            record = resolve_record(action, meta)
            params = resolve_params(action, meta, record)

            perform_request(action, resolve_path_for(meta), record: record, params: params, headers: headers, meta: meta)
            perform_enqueued_jobs
            assert_audit_not_logged(action: action.to_s)
          end
        end
      end

      def generate_show_extras(meta)
        return unless meta.actions.include?(:show)
        show_attrs = meta.check_attributes[:show]
        return unless show_attrs&.any?

        test "show returns expected attributes" do
          record = resolve_record(:show, meta)
          record_id = meta.resource_param ? record.public_send(meta.resource_param) : record.id
          get "#{resolve_path_for(meta)}/#{record_id}", headers: admin_headers, as: :json
          assert_response :success
          data = JSON.parse(response.body).dig("data")

          show_attrs.each { |attr| assert data.key?(attr), "Expected data.#{attr} in response" }
        end
      end

      def generate_index_extras(meta)
        return unless meta.actions.include?(:index)

        index_attrs = meta.check_attributes[:index]
        if index_attrs&.any?
          test "index returns expected attributes" do
            get resolve_path_for(meta), headers: admin_headers, as: :json
            assert_response :success
            data = JSON.parse(response.body).dig("data") || []
            data.each_with_index do |item, i|
              index_attrs.each { |attr| assert item.key?(attr), "Item #{i} missing #{attr}" }
            end
          end
        end

        if meta.index_config[:pagination]
          per_page = meta.index_config[:pagination][:per_page] || 2
          test "index pagination works" do
            assert_pagination_works(resolve_path_for(meta), per_page: per_page)
          end
        end

        if meta.index_config[:ordering]
          test "index ordering works" do
            assert_ordering_works(resolve_path_for(meta),
              order_by: meta.index_config[:ordering][:order_by] || :created_at,
              direction: meta.index_config[:ordering][:direction] || "desc")
          end
        end

        if meta.index_config[:filtering]
          test "index filtering works" do
            assert_filtering_works(resolve_path_for(meta),
              filter_params: meta.index_config[:filtering][:param],
              check: meta.index_config[:filtering][:check])
          end
        end
      end

      def generate_destroy_test(meta)
        return unless meta.actions.include?(:destroy)

        permitted_key = meta.fixture_keys.find { |fk| meta.policy_results[fk][:destroy] }
        return unless permitted_key

        test "destroy removes the record" do
          record = if meta.record_proc
            instance_exec(&meta.record_proc)
          elsif @child_record
            @child_record
          else
            key = meta.param_key
            params = resolve_params(:create, meta, nil)
            meta.model_class.create!(params[key])
          end

          headers = token_headers_for(core_users(permitted_key))
          record_id = meta.resource_param ? record.public_send(meta.resource_param) : record.id
          delete "#{resolve_path_for(meta)}/#{record_id}", headers: headers, as: :json
          assert_response :success
          assert_nil meta.model_class.find_by(id: record.id)
        end
      end

      def generate_absence_tests(meta)
        meta.actions.each do |action|
          absent = meta.check_attributes[:"#{action}_absent"]
          next unless absent&.any?

          test "#{action} excludes hidden attributes" do
            record = resolve_record(action, meta)
            params = resolve_params(action, meta, record)
            path = case action
            when :index then resolve_path_for(meta)
            when :create then resolve_path_for(meta)
            else
                      record_id = meta.resource_param ? record.public_send(meta.resource_param) : record.id
                      "#{resolve_path_for(meta)}/#{record_id}"
            end

            send(http_method_for(action), path, params: params, headers: admin_headers, as: :json)
            assert_response :success

            data = action == :index ? JSON.parse(response.body).dig("data")&.first : JSON.parse(response.body).dig("data")
            absent.each { |attr| assert_not data.key?(attr), "Did not expect #{attr} in #{action} response" }
          end
        end
      end
    end

    private

    def perform_request(action, path, record:, params:, headers:, meta: nil)
      case action
      when :index then get path, headers: headers, as: :json
      when :create then post path, params: params, headers: headers, as: :json
      else
        id = if meta&.resource_param && record
          record.public_send(meta.resource_param)
        elsif record.respond_to?(:id)
          record.id
        else
          "nonexistent"
        end
        case action
        when :show then get "#{path}/#{id}", headers: headers, as: :json
        when :update then patch "#{path}/#{id}", params: params, headers: headers, as: :json
        when :destroy then delete "#{path}/#{id}", headers: headers, as: :json
        end
      end
    end

    def resolve_record(action, meta)
      return instance_exec(&meta.record_proc) if meta.record_proc && %i[show update destroy].include?(action)
      return @child_record if @child_record && %i[show update destroy].include?(action)
      return meta.model_class.first if %i[show update destroy].include?(action)

      nil
    end

    def resolve_params(action, meta, record)
      key = meta.param_key
      case action
      when :create
        if meta.create_params_proc
          result = instance_exec(&meta.create_params_proc)
          result.transform_keys!(&:to_s) if result
          result
        elsif meta.default_create_attrs
          if meta.default_create_attrs.key?("name")
            attrs = meta.default_create_attrs.merge("name" => "#{meta.default_create_attrs['name']} #{SecureRandom.hex(4)}")
          else
            attrs = meta.default_create_attrs
          end
          { key => attrs }
        else
          { key => { "name" => "Test #{SecureRandom.hex(4)}" } }
        end
      when :update
        if meta.update_params_proc
          instance_exec(record, &meta.update_params_proc)
        elsif meta.default_update_attrs
          build_update_params(record, meta)
        elsif record.respond_to?(:name)
          { key => { "name" => "Updated #{record.name}" } }
        end
      else
        nil
      end
    end

    def resolve_path_for(meta)
      source = meta.path_source
      source.respond_to?(:call) ? instance_exec(&source) : source
    end

    def token_headers_for(user)
      token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
      { "Authorization" => "Bearer #{token}" }
    end

    def http_method_for(action)
      { index: :get, show: :get, create: :post, update: :patch, destroy: :delete }[action]
    end

    def minimal_saved_attrs(model_class, parent_param)
      attrs = {}

      model_class.defined_enums.each do |col, mapping|
        attrs[col] = mapping.keys.find { |k| k != "owner" } || mapping.keys.first
      end

      model_class.reflect_on_all_associations(:belongs_to).each do |ref|
        next if ref.polymorphic?
        next if ref.foreign_key.to_s == parent_param.to_s
        next unless ref.klass == Core::User
        attrs[ref.foreign_key] = non_owner_user.id
      end

      attrs
    end

    def non_owner_user
      core_users(:attendee)
    end

    def build_update_params(record, meta)
      key = meta.param_key
      params = {}

      meta.default_update_attrs.each do |column, new_value|
        current = record.public_send(column)
        params[column] = new_value if new_value != current
      end

      return { key => params } if params.any?

      if record.respond_to?(:name)
        { key => { "name" => "Updated #{record.name}" } }
      end
    end

    class Metadata
      attr_reader :path_source, :model_class, :param_key, :fixture_keys, :auditable_actions,
                  :actions, :policy_results, :record_proc,
                  :create_params_proc, :update_params_proc,
                  :skip_authorization, :check_attributes, :index_config,
                  :default_create_attrs, :parent_fixture_key,
                  :default_update_attrs, :controller_class, :resource_param

      def initialize(test_class, options)
        @test_class = test_class
        @options = options
        @path_source = options[:path]
        @model_class = options[:model]
        @record_proc = options[:record]
        @create_params_proc = options[:create_params]
        @update_params_proc = options[:update_params]
        @skip_authorization = options.key?(:skip_authorization) ? options[:skip_authorization] : options[:skip_unauthorized] || false
        @parent_fixture_key = options[:parent_fixture]
        @check_attributes = options[:check_attributes] || {}
        @index_config = options[:index] || {}
        @resource_param = options[:resource_param]
      end

      def build
        resolve_controller
        resolve_model
        resolve_path
        resolve_param_key
        resolve_fixture_keys
        resolve_auditable_actions
        resolve_actions
        resolve_policy_results
        resolve_default_create_attrs
        resolve_default_update_attrs
        resolve_default_check_attributes
        resolve_default_index_config
        register_setup_block if parent_class_present?
      end

      private

      def resolve_controller
        if @options[:controller]
          @controller_class = @options[:controller]
          return
        end

        name = @test_class.name.sub(/Test$/, "")
        parts = name.split(/(?<=[a-z])(?=[A-Z])/)
        @controller_class = "#{parts.join('::')}Controller".constantize
      rescue NameError => e
        raise ArgumentError,
          "Cannot resolve controller from #{@test_class.name}. Provide `controller:` option. (#{e.message})"
      end

      def resolve_path
        return if @path_source

        if parent_class_present?
          @path_source = build_nested_path
        else
          name = @controller_class.name.sub(/Controller$/, "")
          @path_source = "/" + name.underscore.gsub("::", "/")
        end
      end

      def parent_class_present?
        @controller_class.respond_to?(:parent_class) && @controller_class.parent_class.present?
      end

      def child_association
        @controller_class.respond_to?(:parent_association) &&
          @controller_class.parent_association ||
          @model_class.model_name.plural.to_sym
      end

      def controller_namespace
        parts = @controller_class.name.underscore.split("/")
        parts.length > 1 ? "/#{parts[0..-2].join("/")}" : ""
      end

      def build_nested_path
        namespace = controller_namespace
        parent_segment = @controller_class.parent_class.model_name.route_key
          .sub(/^#{@controller_class.parent_class.module_parent.name.underscore}_/, "")
        child_segment = @model_class.model_name.route_key
          .sub(/^#{@model_class.module_parent.name.underscore}_/, "")

        -> { "#{namespace}/#{parent_segment}/#{@parent.id}/#{child_segment}" }
      end

      def register_setup_block
        parent_fixture_key = @parent_fixture_key || :one
        child_assoc = child_association
        parent_route_key = @controller_class.parent_class.model_name.route_key
        mc = @model_class
        pp = @controller_class.parent_param

        @test_class.setup do
          @parent = public_send(parent_route_key, parent_fixture_key)
          @child_record = @parent.public_send(child_assoc).first
          @child_record ||= @parent.public_send(child_assoc).create!(minimal_saved_attrs(mc, pp))
        end
      end

      def resolve_model
        return if @model_class

        if @controller_class.respond_to?(:model_class) && @controller_class.model_class
          @model_class = @controller_class.model_class
        else
          base = @controller_class.name.sub(/Controller$/, "")
          @model_class = base.singularize.constantize
        end
      rescue NameError => e
        raise ArgumentError,
          "Cannot resolve model. Provide `model:` option. (#{e.message})"
      end

      def resolve_param_key
        @param_key = @controller_class.controller_name.singularize
      end

      def resolve_fixture_keys
        fixture_file = Rails.root.join("test/fixtures/core_users.yml")
        raise "Missing test/fixtures/core_users.yml" unless fixture_file.exist?

        raw = File.read(fixture_file)
        yaml = raw.include?("<%") ? ERB.new(raw, trim_mode: "-").result(binding) : raw
        parsed = YAML.safe_load(yaml)
        @core_users_by_key = parsed.select { |_, v| v.is_a?(Hash) }
        @fixture_keys = @options[:fixture_keys]&.map(&:to_sym) || @core_users_by_key.keys.map(&:to_sym)
      end

      def resolve_auditable_actions
        if @controller_class.ancestors.include?(Core::AuditableController)
          configs = @controller_class.respond_to?(:_audit_configs) ? @controller_class._audit_configs : []
          @auditable_actions = configs.flat_map { |c| c[:on] }.uniq
        else
          @auditable_actions = []
        end
      rescue
        @auditable_actions = []
      end

      def resolve_actions
        excluded = Array(@options[:except])
        controller_actions = @controller_class.action_methods.to_a.map(&:to_sym)
        @actions = (%i[index show create update destroy] & controller_actions) - excluded
        raise "No actions to test" if @actions.empty?
      end

      def resolve_policy_results
        @policy_results = {}
        fixture_data = load_fixture_data
        policy_class = resolve_policy_class

        parent = parent_class_present? ? load_parent_fixture_for_policy : nil

        skip_actions = @controller_class._skip_authorize_actions rescue Set.new

        fixture_data.each do |fixture_key, data|
          @policy_results[fixture_key] = {}
          user_mock = build_user_mock(data[:role_codes], data[:perm_codes])

          %i[index show create update destroy].each do |action|
            if skip_actions.include?(action.to_s)
              @policy_results[fixture_key][action] = true
            else
              record = parent_class_present? ? policy_record_for(action, parent) : @model_class.new
              @policy_results[fixture_key][action] =
                policy_class.new(user_mock, record).public_send("#{action}?") rescue false
            end
          end
        end
      end

      def resolve_policy_class
        return @options[:policy_class] if @options[:policy_class]
        return @model_class.policy_name.constantize if @model_class.respond_to?(:policy_name)

        "#{@model_class.name}Policy".constantize
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
        end
      end

      def load_yaml_with_erb(path)
        raw = File.read(path)
        yaml = raw.include?("<%") ? ERB.new(raw, trim_mode: "-").result(binding) : raw
        YAML.safe_load(yaml)
      end

      def resolve_default_create_attrs
        return if @create_params_proc

        fixture_path = Rails.root.join("test/fixtures/#{@model_class.model_name.route_key}.yml")
        return unless fixture_path.exist?

        fixtures = load_yaml_with_erb(fixture_path)
          .select { |_, v| v.is_a?(Hash) }
        return if fixtures.empty?

        first = fixtures.values.first
        attrs = first.except("id", "slug", "created_at", "updated_at")

        if @model_class.respond_to?(:defined_enums)
          @model_class.defined_enums.each do |column, mapping|
            next unless attrs.key?(column)
            non_owner = mapping.keys.find { |k| k != "owner" }
            attrs[column] = non_owner if non_owner
          end
        end

        if parent_class_present?
          parent_fk = @controller_class.parent_param.to_s
          attrs.delete(parent_fk)
          user_key = @fixture_keys.find { |k| k.to_s !~ /admin|owner|super/i } || @fixture_keys.first
          user_id = @core_users_by_key.dig(user_key.to_s, "id")
          attrs["user_id"] = user_id if user_id
        end

        attrs.reject! { |_, v| v.is_a?(String) && v.include?("<%") }

        @default_create_attrs = attrs if attrs.any?
      end

      def resolve_default_update_attrs
        return if @update_params_proc

        @default_update_attrs = nil
        return unless @model_class.respond_to?(:defined_enums)

        enum_cols = {}
        @model_class.defined_enums.each do |column, mapping|
          non_owner = mapping.keys.find { |k| k != "owner" }
          enum_cols[column] = non_owner if non_owner
        end

        @default_update_attrs = enum_cols if enum_cols.any?
      end

      def resolve_default_check_attributes
        return if @options.key?(:check_attributes)

        profile = @controller_class&.new&.send(:serializer_profile) rescue nil
        return resolve_default_check_attributes_from_columns if profile.blank?

        default_fields = profile[:default]&.dig(:fields)
        full_set = resolve_serializer_attribute_names
        action_fields = @actions.each_with_object({}) do |action, hash|
          action_config = profile[action]
          if action_config&.key?(:fields)
            hash[action] = action_config[:fields]
          elsif default_fields
            hash[action] = default_fields
          end
        end

        action_fields.each do |action, attrs|
          next if attrs.nil?
          attr_strings = attrs.map(&:to_s)
          @check_attributes[action] ||= attr_strings
          absent = full_set - attr_strings
          @check_attributes[:"#{action}_absent"] ||= absent if absent.any?
        end
      end

      def resolve_default_check_attributes_from_columns
        columns = @model_class.column_names - %w[id created_at updated_at] rescue []
        @check_attributes[:show] ||= columns if columns.any?
        @check_attributes[:index] ||= columns if columns.any?
      end

      def resolve_serializer_attribute_names
        serializer_class = "#{@model_class.name}Serializer".constantize
        attrs = serializer_class._attributes
        attrs.respond_to?(:keys) ? attrs.keys.map(&:to_s) : attrs.map(&:to_s)
      rescue NameError
        @model_class.column_names
      end

      def resolve_default_index_config
        if @index_config[:pagination].nil? && @index_config[:ordering].nil? && @index_config[:filtering].nil?
          @index_config[:pagination] = { per_page: 2 }
          @index_config[:ordering] = { order_by: "created_at", direction: "desc" }
        end
      end

      def load_parent_fixture_for_policy
        fixture_key = @parent_fixture_key || :one
        fixture_path = Rails.root.join(
          "test/fixtures/#{@controller_class.parent_class.model_name.route_key}.yml"
        )
        return nil unless fixture_path.exist?

        raw = File.read(fixture_path)
        yaml = raw.include?("<%") ? ERB.new(raw, trim_mode: "-").result(binding) : raw
        attrs = YAML.safe_load(yaml)
                  .select { |k, v| v.is_a?(Hash) && k.to_s == fixture_key.to_s }
                  .values
                  .first
        return nil unless attrs

        @controller_class.parent_class.new(attrs)
      end

      def policy_record_for(action, parent)
        return @model_class.new if parent.nil?

        case action
        when :index, :create
          parent.public_send(child_association).new
        when :show, :update, :destroy
          parent.public_send(child_association).first ||
            parent.public_send(child_association).new
        end
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

      def build_user_mock(role_codes, perm_codes)
        MockUser.new(role_codes: role_codes, perm_codes: perm_codes)
      end
    end
  end
end
