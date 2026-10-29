# frozen_string_literal: true

module DatabaseRaceHelper
  RaceResult = Data.define(:results, :errors)

  # Starts every worker at one barrier and gives each worker a checked-out
  # connection. The block must reload records by ID; Active Record instances
  # and transactional test state must never be shared between workers.
  def run_database_race(worker_count: 2, connection_pool: ActiveRecord::Base.connection_pool, &block)
    raise ArgumentError, "worker_count must be at least two" if worker_count.to_i < 2

    ready = Queue.new
    start = Queue.new
    results = Array.new(worker_count)
    errors = Array.new(worker_count)
    threads = worker_threads(worker_count, connection_pool, ready, start, results, errors, &block)

    worker_count.times { ready.pop }
    worker_count.times { start << true }
    threads.each(&:join)
    RaceResult.new(results:, errors: errors.compact)
  ensure
    threads&.each(&:join)
  end

  private

  def worker_threads(worker_count, connection_pool, ready, start, results, errors, &block)
    worker_count.times.map do |index|
      Thread.new do
        ready << true
        start.pop
        results[index] = connection_pool.with_connection { block.call(index) }
      rescue StandardError => error
        errors[index] = error
      end
    end
  end
end
