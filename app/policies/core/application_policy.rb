module Core
  class ApplicationPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def index?
      allowed?(:index)
    end

    def show?
      allowed?(:show)
    end

    def create?
      allowed?(:create)
    end

    def update?
      allowed?(:update)
    end

    def destroy?
      allowed?(:destroy)
    end

    def visible_attributes_for(record:, action:)
      entry = resolve_visibility_entry(action)
      return nil if entry.nil?
      return entry.map(&:to_sym) if entry.is_a?(Array)

      entry[:fields]&.map(&:to_sym)
    end

    def included_associations_for(action:, default_includes:)
      entry = resolve_visibility_entry(action)
      return nil unless entry.is_a?(Hash)

      entry[:include]&.map(&:to_sym)
    end

    def association_fields_for(action:)
      config = resolve_visibility_entry(action)
      return {} unless config.is_a?(Hash)

      config[:association_fields] || {}
    end

    def user_role_key
      return :admin if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
      :default
    end

    private

    def resolve_visibility_entry(action)
      return nil unless self.class.const_defined?(:VISIBILITY, false)

      config = self.class::VISIBILITY[action.to_sym]
      return nil unless config

      if config.key?(user_role_key)
        config[user_role_key]
      else
        config[:default]
      end
    end

    class Scope
      attr_reader :user, :scope

      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.none unless user.has_permission?(index_permission_code)

        scope.all
      end

      private

      def index_permission_code
        "#{resource_name}.index"
      end

      def resource_name
        if scope.respond_to?(:model_name)
          scope.model_name.element
        else
          scope.name.demodulize.underscore.split("/").last
        end
      end
    end

    private

    def allowed?(action)
      return false unless user
      return true if user.super_admin?

      user.has_permission?(permission_code(action))
    end

    def permission_code(action)
      "#{resource_name}.#{action}"
    end

    def resource_name
      target = record.is_a?(Class) ? record : record.class
      target.model_name.element
    end
  end
end
