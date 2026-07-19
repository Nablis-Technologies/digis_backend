# frozen_string_literal: true

module Core
  module Database
    module AdvisoryLock
      module_function

      def acquire!(*parts)
        connection = Core::ApplicationRecord.connection
        raise ArgumentError, "advisory lock requires an open transaction" unless connection.transaction_open?

        key = parts.map(&:to_s).join(":")
        sql = Core::ApplicationRecord.sanitize_sql_array(
          [ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text", key ]
        )
        connection.select_value(sql)
      end
    end
  end
end
