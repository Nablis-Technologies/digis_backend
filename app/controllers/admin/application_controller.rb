module Admin
  class ApplicationController < Core::ApplicationController
    def authorize(record, query = nil, policy_class: nil)
      admin_policy = resolve_admin_policy(record)
      effective_query = (query || "#{action_name}?").to_s
      unless admin_policy.public_send(effective_query)
        raise ::Pundit::NotAuthorizedError, policy: admin_policy, query: effective_query, record: record
      end

      @pundit_authorized = true
      record
    end

    def policy_scope(scope)
      admin_policy = resolve_admin_policy(scope)
      admin_policy.class::Scope.new(pundit_user, scope).resolve
    rescue NameError
      Core::ApplicationPolicy::Scope.new(pundit_user, scope).resolve
    end

    def policy(record)
      resolve_admin_policy(record)
    rescue NameError
      super
    end

    private

    def resolve_admin_policy(record)
      klass = record.is_a?(Class) ? record : record.class
      simple_name = klass.name.demodulize
      "Admin::#{simple_name}Policy".constantize.new(pundit_user, record)
    end
  end
end
