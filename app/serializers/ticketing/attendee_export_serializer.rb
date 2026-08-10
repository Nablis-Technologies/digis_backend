# frozen_string_literal: true

module Ticketing
  class AttendeeExportSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :requested_by_id, :status, :row_mode, :format_version,
               :field_set_digest, :filter_digest, :reason_code, :data_cutoff_at,
               :row_count, :file_sha256, :attempt_count, :processing_started_at,
               :ready_at, :failed_at, :expiring_at, :expired_at, :expires_at,
               :last_download_authorized_at, :failure_code, :created_at, :updated_at
  end
end
