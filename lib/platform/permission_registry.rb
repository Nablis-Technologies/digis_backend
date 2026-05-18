module Platform
  class PermissionRegistry
    REGISTRY = {} # rubocop:disable Style/MutableConstant

    class << self
      def register(namespace, &block)
        builder = RegistryBuilder.new(namespace.to_s)
        builder.instance_eval(&block)
        REGISTRY[namespace.to_s] = builder.permissions
        builder.persist!
        REGISTRY[namespace.to_s]
      end

      def all_permissions
        REGISTRY.values.flatten
      end

      def for_namespace(namespace)
        REGISTRY[namespace.to_s] || []
      end
    end

    class RegistryBuilder
      attr_reader :permissions

      def initialize(namespace)
        @namespace = namespace
        @permissions = []
      end

      def resource(resource_name, actions:, description: nil)
        Array(actions).each do |action|
          @permissions << {
            code: "#{resource_name}.#{action}",
            resource: resource_name.to_s,
            action: action.to_s,
            namespace: @namespace,
            description: description || "#{action} on #{resource_name}"
          }
        end
      end

      def persist!
        @permissions.each do |attributes|
          permission = Platform::Permission.find_or_initialize_by(code: attributes[:code])
          permission.assign_attributes(attributes.merge(active: true))
          permission.save! if permission.new_record? || permission.changed?
        end
      end
    end
  end
end
