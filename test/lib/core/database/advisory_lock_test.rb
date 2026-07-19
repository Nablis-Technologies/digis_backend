# frozen_string_literal: true

require "test_helper"

class Core::Database::AdvisoryLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "requires an open transaction" do
    assert_raises(ArgumentError) do
      Core::Database::AdvisoryLock.acquire!("purchase-limit", "user-1", "ticket-type-1")
    end
  end

  test "acquires a stable transaction lock" do
    result = ApplicationRecord.transaction do
      Core::Database::AdvisoryLock.acquire!("purchase-limit", "user-1", "ticket-type-1")
      :locked
    end

    assert_equal :locked, result
  end
end

class Core::Database::AdvisoryLockSerializationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "serializes two transactions using the same key" do
    first_has_lock = Queue.new
    allow_first_commit = Queue.new
    order = Queue.new

    first = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          Core::Database::AdvisoryLock.acquire!("order", "same-id")
          order << :first_entered
          first_has_lock << true
          allow_first_commit.pop
        end
        order << :first_committed
      end
    end

    first_has_lock.pop
    second = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          Core::Database::AdvisoryLock.acquire!("order", "same-id")
          order << :second_entered
        end
      end
    end

    allow_first_commit << true
    [ first, second ].each(&:join)

    assert_equal %i[first_entered first_committed second_entered], 3.times.map { order.pop }
  end
end
