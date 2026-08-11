# frozen_string_literal: true

module Core
  module Database
    # Transaction-scoped PostgreSQL locks used to serialize cross-row commands.
    # Callers own the global ordering of lock keys; this helper preserves it.
    module AdvisoryLock
      module_function

      # Keep the single-lock API as a shorthand for the ordered multi-lock path.
      def acquire!(*parts)
        acquire_all!(parts)
      end

      # Acquire every key in one statement so no caller can observe a partially
      # acquired lock set. PostgreSQL releases these locks at transaction end.
      def acquire_all!(*parts_list)
        connection = Core::ApplicationRecord.connection
        raise ArgumentError, I18n.t("core.errors.advisory_lock_transaction_required") unless connection.transaction_open?

        keys = parts_list.map { |parts| Array(parts).map(&:to_s).join(":") }
        return if keys.empty?

        placeholders = Array.new(keys.length, "(?)").join(", ")
        sql = Core::ApplicationRecord.sanitize_sql_array(
          [ "SELECT pg_advisory_xact_lock(hashtextextended(lock_key, 0))::text " \
            "FROM (VALUES #{placeholders}) AS retention_locks(lock_key)", *keys ]
        )
        connection.select_values(sql)
      end
    end
  end
end
