module Admin
  class ApplicationController < Core::ApplicationController
    def authorize(record, query = nil, policy_class: nil)
      admin_policy = policy_class&.new(pundit_user, record) || resolve_admin_policy(record)
      effective_query = (query || "#{action_name}?").to_s
      unless admin_policy.public_send(effective_query)
        raise ::Pundit::NotAuthorizedError, policy: admin_policy, query: effective_query, record: record
      end

      @pundit_authorized = true
      record
    end

    def policy_scope(scope, policy_scope_class: nil)
      admin_policy = resolve_admin_policy(scope)
      scope_class = policy_scope_class || admin_policy.class::Scope
      scope_class.new(pundit_user, scope).resolve
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
      klass = policy_target_class(record)
      policy_class = [
        "Admin::#{klass.name}Policy",
        "Admin::#{klass.name.demodulize}Policy"
      ].uniq.filter_map(&:safe_constantize).first
      raise NameError, I18n.t("core.errors.admin_policy_not_found", model: klass.name) unless policy_class

      policy_class.new(pundit_user, record)
    end

    def policy_target_class(record)
      return record if record.is_a?(Class)

      if record.respond_to?(:model) && record.model.is_a?(Class)
        record.model
      else
        record.class
      end
    end
  end
end
