# frozen_string_literal: true

Rails.application.config.after_initialize do
  Core::PhoneVerification::PreviewSender.configure!(
    env: ENV,
    config: Rails.application.config
  )
end
