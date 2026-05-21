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
