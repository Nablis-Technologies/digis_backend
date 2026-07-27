require "pundit"

module Core
  module Authorizable
    extend ActiveSupport::Concern

    include ::Pundit::Authorization

    included do
      class_attribute :_skip_authorize_actions, default: Set.new
      after_action :verify_authorized
      rescue_from ::Pundit::NotAuthorizedError, with: :handle_not_authorized
    end

    class_methods do
      def skip_authorization(**options)
        actions = options[:only] ? Array(options[:only]) : action_methods.to_a
        actions -= Array(options[:except]) if options[:except]
        self._skip_authorize_actions = _skip_authorize_actions.dup.merge(actions.map(&:to_s))
        skip_before_action :authorize_action!, **options
        skip_after_action :verify_authorized, **options
      end
    end

    def skip_authorization_for_action?
      self.class._skip_authorize_actions.include?(action_name)
    end

    def authorize_action!
      policy_target = resolve_policy_target
      return skip_authorization if policy_target.nil?

      authorize(policy_target)
    end

    def pundit_user
      current_user
    end

    def authorize(record, query = nil, policy_class: nil)
      super
    rescue ::Pundit::NotDefinedError
      fallback_policy = Core::ApplicationPolicy.new(pundit_user, record)
      effective_query = (query || "#{action_name}?").to_s

      unless fallback_policy.respond_to?(effective_query, true) && fallback_policy.public_send(effective_query)
        raise ::Pundit::NotAuthorizedError, policy: fallback_policy, query: effective_query, record: record
      end

      record
    end

    def policy_scope(scope, policy_scope_class: nil)
      super
    rescue ::Pundit::NotDefinedError
      Core::ApplicationPolicy::Scope.new(pundit_user, scope).resolve
    end

    private

    def resolve_policy_target
      return policy_target_for_authorization if respond_to?(:policy_target_for_authorization, true)

      nil
    end

    def handle_not_authorized(_exception)
      render_error(:"authorization.errors.unauthorized", status: :forbidden, code: "not_authorized")
    end
  end
end
