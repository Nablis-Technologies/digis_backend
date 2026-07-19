# frozen_string_literal: true

module Core
  class BusinessError < Core::Error
    attr_reader :code, :status, :errors, :meta

    def initialize(message, code:, status:, errors: nil, meta: nil)
      super(message)
      @code = code.to_s
      @status = status
      @errors = errors
      @meta = meta
    end

    def status_code = status
  end
end
