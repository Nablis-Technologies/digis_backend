# frozen_string_literal: true

module Orders
  # Allocates integer minor units over a complete 10,000-basis-point share
  # set. Rational arithmetic preserves exact remainders; stable IDs make ties
  # deterministic regardless of input order. The weighted variant uses the
  # same algorithm for arbitrary positive weights without first rounding those
  # weights to basis points.
  class LargestRemainderAllocator < Core::BaseService
    BASIS_POINTS = 10_000
    Allocation = Data.define(:id, :amount_minor)

    def self.weighted(total_minor:, allocations:)
      new(total_minor:, allocations:, weight_key: :weight).call
    end

    def initialize(total_minor:, allocations:, weight_key: :allocation_basis_points)
      @total_minor = total_minor
      @weight_key = weight_key
      @allocations = allocations.to_a.map { |allocation| normalize(allocation) }
    end

    def call
      validate!
      shares = exact_shares
      distribute_remainder!(shares)
      success(build_allocations(shares))
    end

    private

    attr_reader :allocations, :total_minor, :weight_key

    def normalize(allocation)
      attributes = allocation.to_h
      {
        id: attributes.fetch(:id) { attributes.fetch("id") }.to_s,
        weight: attributes.fetch(weight_key) { attributes.fetch(weight_key.to_s) }
      }
    end

    def validate!
      raise ArgumentError unless total_minor.is_a?(Integer) && total_minor >= 0
      raise ArgumentError if allocations.empty?
      raise ArgumentError unless allocations.map { |allocation| allocation[:id] }.uniq.length == allocations.length
      raise ArgumentError unless allocations.all? { |allocation| valid_share?(allocation) }
      raise ArgumentError unless allocations.sum { |allocation| allocation[:weight] } == denominator
    end

    def valid_share?(allocation)
      id = allocation[:id]
      weight = allocation[:weight]
      id.present? && weight.is_a?(Integer) && weight.positive? && weight <= denominator
    end

    def exact_shares
      allocations.map do |allocation|
        exact = Rational(total_minor * allocation[:weight], denominator)
        { id: allocation[:id], amount_minor: exact.floor, remainder: exact - exact.floor }
      end
    end

    def distribute_remainder!(shares)
      remaining = total_minor - shares.sum { |share| share[:amount_minor] }
      ranked = shares.sort_by { |share| [ -share[:remainder], share[:id] ] }
      ranked.first(remaining).each { |share| share[:amount_minor] += 1 }
    end

    def build_allocations(shares)
      shares.sort_by { |share| share[:id] }
        .map { |share| Allocation.new(id: share[:id], amount_minor: share[:amount_minor]) }
        .freeze
    end

    def denominator
      return BASIS_POINTS if weight_key == :allocation_basis_points

      allocations.sum { |allocation| allocation[:weight] }
    end
  end
end
