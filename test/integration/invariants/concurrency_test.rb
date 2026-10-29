# frozen_string_literal: true

require "test_helper"

module Invariants
  class ConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    test "race helper gives each worker an independent connection and collects errors" do
      race = run_database_race(worker_count: 2) do |index|
        raise "expected race error" if index == 1

        ActiveRecord::Base.connection.object_id
      end

      assert_equal 2, race.results.length
      assert_equal 1, race.errors.length
      assert_instance_of RuntimeError, race.errors.first
      assert race.results.first.is_a?(Integer)
    end
  end
end
