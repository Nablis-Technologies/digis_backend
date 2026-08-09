# frozen_string_literal: true

module Core
  module Database
    module AdvisoryLock
      module_function

      def acquire!(*parts)
        acquire_all!(parts)
      end

      def acquire_all!(*parts_list)
        connection = Core::ApplicationRecord.connection
        raise ArgumentError, "advisory lock requires an open transaction" unless connection.transaction_open?

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
