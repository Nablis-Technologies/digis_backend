module Core
  class BaseService
    class Result
      attr_reader :value, :error

      def self.success(value = nil)
        new(success: true, value: value)
      end

      def self.failure(error)
        new(success: false, error: error)
      end

      def initialize(success:, value: nil, error: nil)
        @success = success
        @value = value
        @error = error
      end

      def success?
        @success
      end

      def failure?
        !success?
      end
    end

    def self.call(...)
      new(...).call
    end

    def call
      raise NotImplementedError, I18n.t("core.errors.service_not_implemented", service: self.class.name)
    end

    protected

    def success(value = nil)
      Result.success(value)
    end

    def failure(error)
      raise ArgumentError, I18n.t("core.errors.invalid_failure_error") unless error.is_a?(Core::Error)

      Result.failure(error)
    end

    def failure_i18n(key, **opts)
      failure(Core::Error.new(I18n.t(key, **opts)))
    end
  end
end
