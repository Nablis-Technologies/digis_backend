# frozen_string_literal: true

if Rails.env.production?
  Rails.application.config.after_initialize do
    service = ActiveStorage::Blob.services.fetch(:private_exports)
    Core::PrivateAttendeeExports.validate_service!(service)
  end
end
