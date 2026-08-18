# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/ci/test_shard"

class CITestShardTest < Minitest::Test
  def test_assigns_every_functional_test_exactly_once_across_shards
    files = %w[
      test/models/a_test.rb
      test/models/b_test.rb
      test/services/c_test.rb
      test/performance/slow_test.rb
    ]
    shards = 2.times.map do |index|
      Ci::TestShard.new(files:, shard_index: index, shard_count: 2).files
    end

    assert_equal %w[test/models/a_test.rb test/models/b_test.rb test/services/c_test.rb], shards.flatten.sort
    assert_empty shards[0] & shards[1]
    refute_includes shards.flatten, "test/performance/slow_test.rb"
  end

  def test_returns_the_same_assignment_regardless_of_input_order
    files = %w[test/z_test.rb test/a_test.rb test/m_test.rb]

    first = Ci::TestShard.new(files:, shard_index: 0, shard_count: 2).files
    second = Ci::TestShard.new(files: files.reverse, shard_index: 0, shard_count: 2).files

    assert_equal first, second
  end

  def test_uses_supplied_weights_to_balance_shards
    files = %w[test/slow_test.rb test/medium_test.rb test/fast_test.rb]
    weights = { "test/slow_test.rb" => 10, "test/medium_test.rb" => 6, "test/fast_test.rb" => 4 }

    shards = 2.times.map do |index|
      Ci::TestShard.new(files:, weights:, shard_index: index, shard_count: 2).files
    end

    assert_equal [ "test/slow_test.rb" ], shards.first
    assert_equal %w[test/fast_test.rb test/medium_test.rb], shards.last.sort
  end

  def test_rejects_invalid_shard_configuration
    assert_raises(ArgumentError) { Ci::TestShard.new(files: [], shard_index: -1, shard_count: 2) }
    assert_raises(ArgumentError) { Ci::TestShard.new(files: [], shard_index: 2, shard_count: 2) }
    assert_raises(ArgumentError) { Ci::TestShard.new(files: [], shard_index: 0, shard_count: 0) }
  end
end
