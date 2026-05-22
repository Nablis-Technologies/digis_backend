module Core
  module AttributeVisibilitySerializer
    def attributes(*args)
      data = super
      allowed = instance_options[:visible_attributes]
      return data if allowed.blank?

      allowed_keys = allowed.map(&:to_sym)
      data.slice(*allowed_keys)
    end
  end
end
