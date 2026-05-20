module Core
  class AuditableRecordNotFoundError < Core::Error
    # Custom exception for when the audit system cannot resolve the record being audited
  end
end
