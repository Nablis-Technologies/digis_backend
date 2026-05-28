module Core
  class AssociationFieldFilter
    def self.apply!(json, association_fields, serializer_class)
      return json unless json.is_a?(Hash) && association_fields.present?

      serializer_class._reflections.each do |name, reflection|
        config = association_fields[name.to_sym]
        next if config.nil?

        json_key = find_json_key(json, reflection)
        next if json_key.nil? || json[json_key].nil?

        if config[:fields].present?
          allowed = config[:fields].map(&:to_sym)
          case json[json_key]
          when Array
            json[json_key].each { |item| item.slice!(*allowed) }
          when Hash
            json[json_key].slice!(*allowed)
          end
        end

        if config[:association_fields].present?
          child_serializer = reflection.options[:serializer]
          next unless child_serializer

          items = Array.wrap(json[json_key])
          items.each { |item| apply!(item, config[:association_fields], child_serializer) }
        end
      end

      json
    end

    def self.find_json_key(json, reflection)
      raw = reflection.options[:key] || reflection.name
      sym = raw.to_sym
      str = raw.to_s
      return sym if json.key?(sym)
      return str if json.key?(str)
      nil
    end
  end
end
