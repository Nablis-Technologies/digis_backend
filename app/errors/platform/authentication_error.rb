module Platform
  class AuthenticationError < Platform::Error
    attr_reader :status_code, :code

    def initialize(message = "Authentication failed", status_code: 401, code: "authentication_failed")
      super(message)
      @status_code = status_code
      @code = code
    end

    def to_h
      {
        error: message,
        code: code,
        status: status_code
      }
    end
  end
end
