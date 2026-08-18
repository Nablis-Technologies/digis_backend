# frozen_string_literal: true

module Ci
  # Partitions tracked test files deterministically so matrix jobs cover each file once.
  class TestShard
    PERFORMANCE_PREFIX = "test/performance/"
    TEST_FILE_SUFFIX = "_test.rb"

    def initialize(files:, shard_index:, shard_count:, weights: {})
      @files = Array(files).map(&:to_s).uniq
      @weights = weights.to_h.transform_keys(&:to_s)
      @shard_index = shard_index
      @shard_count = shard_count
      validate_configuration!
    end

    def files
      buckets = Array.new(@shard_count) { [] }
      loads = Array.new(@shard_count, 0)

      weighted_files.each do |path|
        shard_index = loads.each_index.min_by { |index| [ loads[index], index ] }
        buckets.fetch(shard_index) << path
        loads[shard_index] += weight_for(path)
      end

      buckets.fetch(@shard_index).sort
    end

    private

    def validate_configuration!
      return if @shard_count.is_a?(Integer) && @shard_count.positive? &&
        @shard_index.is_a?(Integer) && @shard_index.between?(0, @shard_count - 1)

      raise ArgumentError, "shard index must be within a positive shard count"
    end

    def weighted_files
      @files
        .select { |path| functional_test_file?(path) }
        .sort_by { |path| [ -weight_for(path), path ] }
    end

    def functional_test_file?(path)
      path.end_with?(TEST_FILE_SUFFIX) && !path.start_with?(PERFORMANCE_PREFIX)
    end

    def weight_for(path)
      weight = Integer(@weights.fetch(path, 1))
      return weight if weight.positive?

      raise ArgumentError, "test shard weights must be positive"
    end
  end
end
