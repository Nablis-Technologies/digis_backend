# frozen_string_literal: true

# Shared query-count instrumentation for deterministic performance tests. It
# counts uncached application SQL only; transaction and schema noise are not a
# request budget and therefore remain outside the measurement.
module PerformanceQueryHelpers
  IGNORED_SQL_NAMES = %w[SCHEMA TRANSACTION].freeze

  private

  def count_database_queries
    count = 0
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      next if IGNORED_SQL_NAMES.include?(payload[:name].to_s)
      next if payload[:cached]

      count += 1
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    count
  end
end
