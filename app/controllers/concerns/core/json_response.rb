module Core
  module JsonResponse
    extend ActiveSupport::Concern

    def serialize(data, options = {})
      case data
      when ActiveRecord::Base, ActiveRecord::Relation
        ActiveModelSerializers::SerializableResource.new(data, options).as_json
      when Hash
        serialize_hash(data, options)
      when Array
        data.map { |value| serialize(value, options) }
      else
        data
      end
    end

    def serializer_profile
      {}
    end

    def resolved_visible_attributes(data)
      profile = serializer_profile
      action_sym = action_name.to_sym
      action_config = profile[action_sym] || {}
      default_conf = profile[:default] || {}
      controller_fields = action_config.key?(:fields) ? action_config[:fields] : default_conf[:fields]
      policy_fields = policy_visible_attributes_for(data)

      return nil if controller_fields.nil? && policy_fields.nil?
      return controller_fields.map(&:to_sym) if policy_fields.nil?
      return policy_fields.map(&:to_sym) if controller_fields.nil?

      controller_fields.map(&:to_sym) & policy_fields.map(&:to_sym)
    end

    def policy_visible_attributes_for(data)
      return nil unless data.is_a?(ActiveRecord::Base) || data.is_a?(ActiveRecord::Relation)

      target = data.is_a?(ActiveRecord::Relation) ? @clazz&.new : data
      return nil unless target

      pol = policy(target)
      return nil unless pol&.respond_to?(:visible_attributes_for)

      pol.visible_attributes_for(record: target, action: action_name)
    end

    def render_success(message = nil, data: nil, status: :ok, serializer_options: {}, pagination: nil, meta: nil, **options)
      response = { success: true }
      resolved_message = resolve_message(message, type: :success)
      response[:message] = resolved_message if resolved_message.present?
      response[:data] = serialize(data, serializer_options.except(:pagination).merge(
        visible_attributes: resolved_visible_attributes(data)
      )) unless data.nil?
      response[:pagination] = pagination || serializer_options[:pagination] if pagination.present? || serializer_options[:pagination].present?
      response[:meta] = meta if meta.present?
      response.merge!(options) if options.present?

      render json: response, status: status
    end

    def render_error(message = nil, status: :unprocessable_entity, errors: nil, code: nil, meta: nil, **options)
      response = { success: false }
      resolved_message = resolve_message(message, type: :error)
      response[:error] = resolved_message if resolved_message.present?
      response[:errors] = normalize_errors(errors) if errors.present?
      response[:code] = code if code.present?
      response[:meta] = meta if meta.present?
      response.merge!(options) if options.present?

      render json: response, status: status
    end

    private

    def serialize_hash(data, options)
      data.each_with_object({}) do |(key, value), serialized|
        key_options = options[key]

        if key_options.present? && (value.is_a?(ActiveRecord::Base) || value.is_a?(ActiveRecord::Relation))
          serializer_options = key_options.is_a?(Hash) ? key_options : {}
          serialized[key] = serialize(value, serializer_options)
        else
          serialized[key] = serialize(value, options)
        end
      end
    end

    def resolve_message(message, type:)
      if message.present?
        return message.to_s unless message.is_a?(Symbol)
        return I18n.t(message) if I18n.exists?(message)
        return message.to_s
      end

      key = inferred_message_key(type)
      return nil unless key && I18n.exists?(key)

      I18n.t(key)
    end

    def inferred_message_key(type)
      model_key = @clazz&.name&.demodulize&.underscore
      return nil if model_key.blank?

      segment = type == :success ? "success" : "errors"
      "#{model_key}.#{segment}.#{action_name}"
    end

    def normalize_errors(errors)
      case errors
      when ActiveModel::Errors
        errors.to_hash(true)
      when String
        [ errors ]
      else
        errors
      end
    end
  end
end
