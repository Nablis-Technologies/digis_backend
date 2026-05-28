module Core
  module JsonResponse
    extend ActiveSupport::Concern

    def serialize(data, options = {})
      case data
      when ActiveRecord::Base
        serialize_record(data, options)
      when ActiveRecord::Relation
        serialize_relation(data, options)
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
      pol = policy_for_data(data)
      return nil unless pol&.respond_to?(:visible_attributes_for)

      target = data.is_a?(ActiveRecord::Relation) ? @clazz&.new : data
      return nil unless target

      pol.visible_attributes_for(record: target, action: action_name)
    end

    def resolved_association_fields(data, action)
      pol = policy_for_data(data)
      return {} unless pol&.respond_to?(:association_fields_for)

      pol.association_fields_for(action:)
    end

    def render_success(message = nil, data: nil, status: :ok, serializer_options: {}, pagination: nil, meta: nil, **options)
      if self.class.respond_to?(:default_serializer) && self.class.default_serializer && !serializer_options.key?(:serializer)
        serializer_options[:serializer] = self.class.default_serializer
      end
      response = { success: true }
      resolved_message = resolve_message(message, type: :success)
      response[:message] = resolved_message if resolved_message.present?
      response[:data] = serialize(data, serializer_options.except(:pagination).merge(
        visible_attributes: resolved_visible_attributes(data),
        association_fields: build_association_options(resolved_association_fields(data, action_name))
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

    def policy_for_data(data)
      return nil unless data.is_a?(ActiveRecord::Base) || data.is_a?(ActiveRecord::Relation)

      target = if data.is_a?(ActiveRecord::Relation)
        return nil unless @clazz
        @clazz.new
      else
        data
      end

      policy(target)
    end

    def serialize_record(data, options = {})
      assoc_fields = options.delete(:association_fields)
      serializer_class = options[:serializer] || ActiveModelSerializers::SerializableResource.new(data).serializer
      result = ActiveModelSerializers::SerializableResource.new(data, options).as_json

      if assoc_fields.present? && serializer_class
        Core::AssociationFieldFilter.apply!(result, assoc_fields, serializer_class)
      end

      result
    end

    def serialize_relation(data, options = {})
      assoc_fields = options.delete(:association_fields)
      explicit_serializer = options.delete(:serializer)

      if explicit_serializer
        result = data.map { |record| ActiveModelSerializers::SerializableResource.new(record, options.merge(serializer: explicit_serializer)).as_json }
      else
        result = ActiveModelSerializers::SerializableResource.new(data, options).as_json
      end

      if assoc_fields.present? && result.is_a?(Array) && result.first.is_a?(Hash)
        serializer_class = explicit_serializer || \
          (data.respond_to?(:klass) && ActiveModelSerializers::SerializableResource.new(data.klass.new).serializer)
        result.each { |item| Core::AssociationFieldFilter.apply!(item, assoc_fields, serializer_class) } if serializer_class
      end

      result
    end

    def build_association_options(fields)
      return {} if fields.blank?

      fields.each_with_object({}) do |(key, value), opts|
        next if value.nil?

        entry = {}
        entry[:fields] = value[:fields].map(&:to_sym) if value[:fields].present?
        if value[:association_fields].present?
          entry[:association_fields] = build_association_options(value[:association_fields])
        end
        opts[key.to_sym] = entry.presence
      end.compact
    end

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
