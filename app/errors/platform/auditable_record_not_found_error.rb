module Platform
  class AuditableRecordNotFoundError < Platform::Error
    # Custom exception for when the audit system cannot resolve the record being audited
  end
end
