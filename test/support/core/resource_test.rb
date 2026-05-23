module Core
  module ResourceTest
    extend ActiveSupport::Concern

    included do
      include Core::AuthTestHelpers
      include Core::AuditTestHelpers
      include Core::CrudTestHelpers
      include Core::PaginationTestHelpers
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
      end

      private

      def generate_tests(action, meta)
        unless meta.skip_authorization
          test "#{action} fails for unauthenticated user" do
            perform_request(action, meta.path, record: nil, params: nil, headers: {})
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

            perform_request(action, meta.path, record: record, params: params, headers: headers)
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
              perform_request(action, meta.path, record: record, params: params, headers: headers)
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

            perform_request(action, meta.path, record: record, params: params, headers: headers)
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
          get "#{meta.path}/#{record.id}", headers: admin_headers, as: :json
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
            get meta.path, headers: admin_headers, as: :json
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
            assert_pagination_works(meta.path, per_page: per_page)
          end
        end

        if meta.index_config[:ordering]
          test "index ordering works" do
            assert_ordering_works(meta.path,
              order_by: meta.index_config[:ordering][:order_by] || :created_at,
              direction: meta.index_config[:ordering][:direction] || "desc")
          end
        end

        if meta.index_config[:filtering]
          test "index filtering works" do
            assert_filtering_works(meta.path,
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
          key = meta.param_key
          params = resolve_params(:create, meta, nil)
          record = meta.model_class.create!(params[key])

          headers = token_headers_for(core_users(permitted_key))
          delete "#{meta.path}/#{record.id}", headers: headers, as: :json
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
                   when :index then meta.path
                   when :create then meta.path
                   else "#{meta.path}/#{record.id}"
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

    def perform_request(action, path, record:, params:, headers:)
      id = record.respond_to?(:id) ? record.id : "nonexistent"
      case action
      when :index then get path, headers: headers, as: :json
      when :show then get "#{path}/#{id}", headers: headers, as: :json
      when :create then post path, params: params, headers: headers, as: :json
      when :update then patch "#{path}/#{id}", params: params, headers: headers, as: :json
      when :destroy then delete "#{path}/#{id}", headers: headers, as: :json
      end
    end

    def resolve_record(action, meta)
      return meta.record_proc.call if meta.record_proc
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
          attrs = meta.default_create_attrs.merge("name" => "#{meta.default_create_attrs['name']} #{SecureRandom.hex(4)}")
          { key => attrs }
        else
          { key => { "name" => "Test #{SecureRandom.hex(4)}" } }
        end
      when :update
        if meta.update_params_proc
          instance_exec(record, &meta.update_params_proc)
        else
          { key => { "name" => "Updated #{record.name}" } }
        end
      else
        nil
      end
    end

    def token_headers_for(user)
      token = Core::TokenService.issue(Core::TokenService.access_token_payload(user))
      { "Authorization" => "Bearer #{token}" }
    end

    def http_method_for(action)
      { index: :get, show: :get, create: :post, update: :patch, destroy: :delete }[action]
    end

    class Metadata
      attr_reader :path, :model_class, :param_key, :fixture_keys, :auditable_actions,
                  :actions, :policy_results, :record_proc,
                  :create_params_proc, :update_params_proc,
                  :skip_authorization, :check_attributes, :index_config,
                  :default_create_attrs

      def initialize(test_class, options)
        @test_class = test_class
        @options = options
        @path = options[:path]
        @model_class = options[:model]
        @record_proc = options[:record]
        @create_params_proc = options[:create_params]
        @update_params_proc = options[:update_params]
        @skip_authorization = options.key?(:skip_authorization) ? options[:skip_authorization] : options[:skip_unauthorized] || false
        @check_attributes = options[:check_attributes] || {}
        @index_config = options[:index] || {}
      end

      def build
        resolve_controller
        resolve_path
        resolve_model
        resolve_param_key
        resolve_fixture_keys
        resolve_auditable_actions
        resolve_actions
        resolve_policy_results
        resolve_default_create_attrs
        resolve_default_check_attributes
        resolve_default_index_config
      end

      private

      def resolve_controller
        name = @test_class.name.sub(/Test$/, "")
        parts = name.split(/(?<=[a-z])(?=[A-Z])/)
        @controller_class = "#{parts.join('::')}Controller".constantize
      rescue NameError => e
        raise ArgumentError,
          "Cannot resolve controller from #{@test_class.name}. Provide `controller:` option. (#{e.message})"
      end

      def resolve_path
        return if @path

        name = @controller_class.name.sub(/Controller$/, "")
        @path = "/" + name.underscore.gsub("::", "/")
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

        @fixture_keys = YAML.safe_load_file(fixture_file)
          .select { |_, v| v.is_a?(Hash) }
          .keys
          .map(&:to_sym)
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
        record = @model_class.new
        skip_actions = @controller_class._skip_authorize_actions rescue Set.new

        fixture_data.each do |fixture_key, data|
          @policy_results[fixture_key] = {}
          user_mock = build_user_mock(data[:role_codes], data[:perm_codes])

          %i[index show create update destroy].each do |action|
            if skip_actions.include?(action.to_s)
              @policy_results[fixture_key][action] = true
            else
              @policy_results[fixture_key][action] =
                policy_class.new(user_mock, record).public_send("#{action}?") rescue false
            end
          end
        end
      end

      def resolve_policy_class
        if @model_class.respond_to?(:policy_name)
          @model_class.policy_name.constantize
        else
          "#{@model_class.name}Policy".constantize
        end
      end

      def load_fixture_data
        base = Rails.root.join("test/fixtures")

        users = YAML.safe_load_file(base.join("core_users.yml"))
          .select { |_, v| v.is_a?(Hash) }

        roles = YAML.safe_load_file(base.join("core_roles.yml"))
          .select { |_, v| v.is_a?(Hash) }
          .to_h { |_, v| [ v["id"], v["code"] ] }

        user_roles = YAML.safe_load_file(base.join("core_user_roles.yml"))
          .select { |_, v| v.is_a?(Hash) }

        role_permissions = YAML.safe_load_file(base.join("core_role_permissions.yml"))
          .select { |_, v| v.is_a?(Hash) }

        permissions = YAML.safe_load_file(base.join("core_permissions.yml"))
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

      def resolve_default_create_attrs
        return if @create_params_proc

        fixture_path = Rails.root.join("test/fixtures/#{@model_class.model_name.route_key}.yml")
        return unless fixture_path.exist?

        fixtures = YAML.safe_load_file(fixture_path)
          .select { |_, v| v.is_a?(Hash) }
        return if fixtures.empty?

        first = fixtures.values.first
        attrs = first.except("id", "slug", "created_at", "updated_at")
        attrs.reject! { |_, v| v.is_a?(String) && v.include?("<%") }

        @default_create_attrs = attrs if attrs.any?
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
