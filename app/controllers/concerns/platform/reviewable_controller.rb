module Platform
  module ReviewableController
    extend ActiveSupport::Concern
    include Platform::JsonResponse

    included do
      class_attribute :review_context_configs, default: {}
      class_attribute :reviewable_model_class, default: nil

      self.review_context_configs = default_context_config.dup
      define_default_review_actions

      before_action :set_reviewable_resource, if: :review_action?
      before_action :authorize_review_action!, if: :review_action?
    end

    class_methods do
      def reviewable_model(model_class)
        self.reviewable_model_class = model_class
      end

      def reviewable_context(context_name, options = {})
        statuses = options[:statuses]&.map(&:to_s) || %w[pending approved rejected modify]
        initial_status = options[:initial_status]&.to_s || "pending"

        transitions = if options[:transitions].is_a?(Array)
                        validate_linear_transitions(options[:transitions], statuses, context_name)
                        build_linear_transitions(options[:transitions])
        else
                        options[:transitions] || {}
        end

        config = {
          statuses: statuses,
          initial_status: initial_status,
          transitions: transitions,
          actions: options[:actions] || default_actions
        }

        validate_action_config(config[:actions], config[:statuses], context_name)
        unless config[:statuses].include?(config[:initial_status])
          raise ArgumentError, "Initial status '#{config[:initial_status]}' in context '#{context_name}' must be one of: #{config[:statuses].join(', ')}"
        end

        self.review_context_configs = review_context_configs.merge(context_name.to_sym => config)
        config[:actions].each_key { |action_name| define_review_action_method(action_name) unless method_defined?(action_name) }
      end

      def define_default_review_actions
        default_context_config.each_value do |config|
          config[:actions].each_key { |action_name| define_review_action_method(action_name) }
        end
      end

      def define_review_action_method(action_name)
        define_method(action_name) do
          action_config = context_config[:actions][action_name.to_sym]
          return render_error("Action '#{action_name}' is not defined for context '#{current_review_context}'", status: :bad_request) unless action_config

          perform_review_action(**action_config.slice(:status, :require_feedback, :require_submission_ready, :after, :update_model, :from))
        end
      end

      def default_actions
        {
          submit: { status: "pending", require_submission_ready: true },
          approve: { status: "approved" },
          reject: { status: "rejected", require_feedback: true },
          request_modification: { status: "modify", require_feedback: true },
          resubmit: { status: "pending", update_model: true, from: "modify" }
        }
      end

      def default_context_config
        {
          default: {
            statuses: %w[draft pending approved rejected modify],
            initial_status: "draft",
            transitions: {
              "draft" => [ "pending" ],
              "pending" => %w[approved rejected modify],
              "modify" => [ "pending" ]
            },
            actions: default_actions
          }
        }
      end

      def validate_action_config(actions, statuses, context_name)
        actions.each do |action_name, opts|
          unless statuses.include?(opts[:status].to_s)
            raise ArgumentError, "Action '#{action_name}' in context '#{context_name}' maps to invalid status '#{opts[:status]}'"
          end

          next unless opts[:from].present?

          invalid_from = Array(opts[:from]).map(&:to_s) - statuses
          next if invalid_from.empty?

          raise ArgumentError, "Action '#{action_name}' in context '#{context_name}' has invalid from statuses: #{invalid_from.join(', ')}"
        end
      end

      def validate_linear_transitions(transitions, statuses, context_name)
        transitions.each do |status|
          next if statuses.include?(status.to_s)

          raise ArgumentError, "Transition status '#{status}' in context '#{context_name}' must be one of: #{statuses.join(', ')}"
        end
      end

      def build_linear_transitions(transitions)
        transitions.each_with_object({}).with_index do |(status, hash), index|
          next_status = transitions[index + 1]
          hash[status.to_s] = next_status ? [ next_status.to_s ] : []
        end
      end

      def review_action_names
        configured = review_context_configs.values.flat_map { |config| config[:actions].keys }
        (configured + default_context_config[:default][:actions].keys).uniq
      end
    end

    private

    def review_action?
      self.class.review_action_names.include?(action_name.to_sym)
    end

    def perform_review_action(status:, require_feedback: false, require_submission_ready: false, after: nil, update_model: false, from: nil)
      current_review = reviewable_resource.current_review_for(current_review_context)
      current_status = current_review&.status || context_config[:initial_status]

      return render_error(transition_from_error(from, current_status), status: :unprocessable_entity) unless allowed_from_status?(from, current_status)
      return render_error("Resource must be complete before submission", status: :unprocessable_entity) if require_submission_ready && !submission_ready?(reviewable_resource)

      feedback = extract_feedback(require_feedback, status)
      return if performed?
      return render_error("Cannot transition from '#{current_status}' to '#{status}'", status: :unprocessable_entity) unless valid_transition?(current_status, status)

      ActiveRecord::Base.transaction do
        apply_model_updates! if update_model
        return if performed?

        review = current_review || reviewable_resource.build_review_for(current_review_context)
        review.assign_attributes(
          status: status,
          feedback: feedback,
          reviewed_by: current_user,
          reviewed_at: Time.current
        )

        before_review_action(review)
        review.save!
        execute_after_callbacks(review, after)
        after_review_action(review)
      end

      render_success(data: reviewable_resource.reload)
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound => error
      render_error(error.message, status: :not_found)
    rescue ActionController::ParameterMissing
      raise
    end

    def extract_feedback(require_feedback, status)
      return nil unless require_feedback

      feedback_data = params[:review_feedback]
      feedback_data = feedback_data.to_unsafe_h if feedback_data.respond_to?(:to_unsafe_h)
      return render_error("Feedback is required for #{status}", status: :unprocessable_entity) if feedback_data.blank?

      feedback_data
    end

    def apply_model_updates!
      updates = model_params
      return if updates.blank?

      return if reviewable_resource.update(updates)

      render_error(errors: reviewable_resource.errors, status: :unprocessable_entity)
    end

    def execute_after_callbacks(review, callbacks = nil)
      action_callbacks = callbacks || context_config[:actions][action_name.to_sym]&.[](:after)
      return unless action_callbacks

      Array(action_callbacks).each do |callback|
        if callback.is_a?(Symbol)
          send(callback, review)
        elsif callback.respond_to?(:call)
          callback.call(review)
        else
          raise ArgumentError, "Invalid callback: #{callback.inspect}"
        end
      end
    end

    def current_review_context
      params[:context]&.to_sym || :default
    end

    def available_contexts
      contexts = self.class.review_context_configs.keys
      contexts << :default unless contexts.include?(:default)
      contexts
    end

    def context_config
      config = self.class.review_context_configs[current_review_context]
      config = self.class.default_context_config[:default] if current_review_context == :default && config.nil?
      return config if config.present?

      raise ArgumentError, "Invalid context '#{current_review_context}'. Available contexts: #{available_contexts.join(', ')}"
    end

    def valid_transition?(from, to)
      transitions = context_config[:transitions]
      return true if transitions.blank?

      allowed_targets = transitions[from || context_config[:initial_status]] || []
      allowed_targets.include?(to)
    end

    def allowed_from_status?(from, current_status)
      return true if from.blank?

      Array(from).map(&:to_s).include?(current_status)
    end

    def transition_from_error(from, current_status)
      allowed = Array(from).join(", ")
      "Action '#{action_name}' can only be performed from: #{allowed}. Current status is '#{current_status}'"
    end

    def authorize_review_action!
      permission_code = "#{controller_name}.#{action_name}"
      authorized = current_user&.has_permission?(permission_code)

      return render_error("You are not authorized to perform this action", status: :forbidden, code: "not_authorized") unless authorized

      if %w[submit resubmit].include?(action_name) && owner_enforcement_failed?
        return render_error("You are not authorized to perform this action", status: :forbidden, code: "not_authorized")
      end

      if %w[approve reject request_modification].include?(action_name) && self_review_attempt?
        return render_error("You are not authorized to perform this action", status: :forbidden, code: "not_authorized")
      end

      skip_authorization
    end

    def owner_enforcement_failed?
      return false if current_user&.super_admin?
      return false unless @reviewable_resource.respond_to?(:user)
      return false if @reviewable_resource.user.nil?

      @reviewable_resource.user != current_user
    end

    def self_review_attempt?
      @reviewable_resource.respond_to?(:user) && @reviewable_resource.user == current_user
    end

    def submission_ready?(resource)
      return true unless resource.respond_to?(:valid?)

      resource.valid?
    end

    def before_review_action(review)
      return unless respond_to?(:before_reviewable_action, true)

      before_reviewable_action(review, reviewable_resource, current_review_context)
    end

    def after_review_action(review)
      return unless respond_to?(:after_reviewable_action, true)

      after_reviewable_action(review, reviewable_resource, current_review_context)
    end

    def model_params
      resource_name = controller_name.singularize
      params_method = "#{resource_name}_params"
      return send(params_method) if respond_to?(params_method, true)
      return reviewable_params if respond_to?(:reviewable_params, true)

      {}
    end

    def model_class
      return self.class.reviewable_model_class if self.class.reviewable_model_class.present?

      model_name = controller_name.classify
      namespaced_model = "#{self.class.name.deconstantize}::#{model_name}"
      namespaced_model.safe_constantize || model_name.constantize
    end

    def set_reviewable_resource
      @reviewable_resource = model_class.find(params[:id])
    rescue ActiveRecord::RecordNotFound => error
      render_error(error.message, status: :not_found)
    rescue NameError => error
      render_error("Reviewable configuration error: #{error.message}", status: :internal_server_error)
    end

    def reviewable_resource
      @reviewable_resource
    end
  end
end
