module Core
  module Common
    extend ActiveSupport::Concern
    include Core::Filterable
    include Core::JsonResponse
    include Core::Pagination

    included do
      class_attribute :model_class, default: nil
      class_attribute :parent_class, default: nil
      class_attribute :parent_param, default: nil
      class_attribute :parent_association, default: nil
      class_attribute :resource_param, default: :id
      class_attribute :default_serializer, default: nil
      before_action :set_clazz
      before_action :set_parent
      before_action :set_object, only: %i[show update destroy]
    end

    def index
      if self.class.parent_class
        authorize @parent.public_send(child_association).new, :index? unless skip_authorization_for_action?
        data, serializer_options = resolve_block_result(default: policy_scope(@parent.public_send(child_association)))
      else
        authorize @clazz.new, :index? unless skip_authorization_for_action?
        data, serializer_options = resolve_block_result(default: policy_scope(@clazz))
      end

      data = apply_index_scope(data)
      data = data.includes(eager_loaded_associations) if data.respond_to?(:includes)
      data = filter_records(data)
      data = apply_ordering(data)

      total_count = data.count if paginated_request?
      data = apply_pagination(data) if paginated_request?

      serializer_options[:include] ||= renderable_associations

      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(data: data, serializer_options: serializer_options, pagination: pagination)
    end

    def show
      authorize @obj unless skip_authorization_for_action?

      data, serializer_options = resolve_block_result(default: @obj)
      data = @clazz.includes(eager_loaded_associations).find(data.id) if data.is_a?(@clazz)

      serializer_options[:include] ||= renderable_associations

      render_success(data: data, serializer_options: serializer_options)
    end

    def create
      object = if self.class.parent_class
        @parent.public_send(child_association).new(model_params)
      else
        @clazz.new(model_params)
      end

      authorize object unless skip_authorization_for_action?

      serializer_options = {}

      ActiveRecord::Base.transaction do
        if object.save
          @obj = object
          after_create_hook(object) if respond_to?(:after_create_hook, true)

          object = @clazz.includes(eager_loaded_associations).find(object.id)
          @obj = object

          serializer_options[:include] ||= renderable_associations

          render_success(data: object, serializer_options: serializer_options, status: :created)
        else
          render_error(errors: object.errors, status: :unprocessable_entity)
        end
      end
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound => error
      render_error(error.message, status: :not_found)
    rescue Pundit::NotAuthorizedError
      raise
    end

    def update
      authorize @obj unless skip_authorization_for_action?

      object, serializer_options = resolve_block_result(default: @obj)

      ActiveRecord::Base.transaction do
        if object.update(model_params)
          after_update_hook(object) if respond_to?(:after_update_hook, true)

          object = @clazz.includes(eager_loaded_associations).find(object.id)
          @obj = object

          serializer_options[:include] ||= renderable_associations

          render_success(data: object, serializer_options: serializer_options)
        else
          render_error(errors: object.errors, status: :unprocessable_entity)
        end
      end
    rescue ActiveRecord::RecordInvalid => error
      render_error(error.record.errors.full_messages.first, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound => error
      render_error(error.message, status: :not_found)
    rescue Pundit::NotAuthorizedError
      raise
    end

    def destroy
      authorize @obj unless skip_authorization_for_action?
      if @obj.respond_to?(:soft_delete)
        @obj.soft_delete!
      else
        @obj.destroy!
      end
      render_success(status: :ok)
    end

    private

    def set_clazz
      @clazz = self.class.model_class
      return if @clazz.present?

      raise ArgumentError, "#{self.class.name} must declare self.model_class"
    end

    def set_parent
      return unless self.class.parent_class

      param_name = self.class.parent_param || :"#{self.class.parent_class.model_name.singular}_id"
      @parent = self.class.parent_class.find(params[param_name])
    end

    def child_association
      self.class.parent_association || @clazz.model_name.plural.to_sym
    end

    def set_object
      lookup = params[self.class.resource_param]
      if self.class.parent_class
        @obj = @parent.public_send(child_association)
                .includes(eager_loaded_associations)
                .find_by!(self.class.resource_param => lookup)
      else
        @obj = @clazz.includes(eager_loaded_associations)
                .find_by!(self.class.resource_param => lookup)
      end
    end

    def resolve_block_result(default:)
      return [ default, {} ] unless block_given?

      incoming = yield

      if incoming.is_a?(Array)
        [ incoming[0], incoming[1] || {} ]
      elsif incoming.is_a?(Hash)
        [ default, incoming ]
      else
        [ incoming, {} ]
      end
    end

    def eager_load_config
      {}
    end

    def eager_loaded_associations
      config = eager_load_config
      action_key = action_name.to_sym
      if config.key?(action_key)
        config[action_key]
      elsif config.key?(:default)
        config[:default]
      else
        []
      end
    end

    def policy_sample
      @obj || @clazz&.new
    end

    def apply_index_scope(scope)
      scope
    end

    def allowed_order_columns
      %w[id created_at updated_at]
    end

    def serializer_includes_for_action(action)
      profile = serializer_profile
      action_sym = action.to_sym
      action_config = profile[action_sym] || {}
      default_conf = profile[:default] || {}
      action_config.key?(:include) ? action_config[:include] : default_conf[:include] || []
    end

    def renderable_associations
      controller_includes = serializer_includes_for_action(action_name)
      pol = policy_for_data(policy_sample)
      return controller_includes unless pol&.respond_to?(:included_associations_for)

      policy_includes = pol.included_associations_for(
        action: action_name,
        default_includes: controller_includes
      )
      return controller_includes if policy_includes.nil?

      controller_includes & policy_includes
    end

    def model_params
      raise NotImplementedError, "#{self.class.name} must implement #model_params"
    end
  end
end
