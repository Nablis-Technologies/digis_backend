# frozen_string_literal: true

module Core
  module PrivateAttendeeExports
    class InsecureStorage < Core::Error; end

    module_function

    def validate_service!(service)
      if mirror_service?(service)
        validate_service!(service.primary)
        service.mirrors.each { |mirror| validate_service!(mirror) }
        return
      end
      return unless service.class.name == "ActiveStorage::Service::DiskService" ||
        (service.respond_to?(:public?) && service.public?)

      fail InsecureStorage, "private attendee exports require non-public provider storage"
    end

    def mirror_service?(service)
      service.respond_to?(:primary) && service.respond_to?(:mirrors)
    end
  end
end
