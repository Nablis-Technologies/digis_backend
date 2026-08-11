# frozen_string_literal: true

module Orders
  # Allocates integer minor units over a complete 10,000-basis-point share
  # set. Rational arithmetic preserves exact remainders; stable IDs make ties
  # deterministic regardless of input order.
  class LargestRemainderAllocator < Core::BaseService
    BASIS_POINTS = 10_000
    Allocation = Data.define(:id, :amount_minor)

    def initialize(total_minor:, allocations:)
      @total_minor = total_minor
      @allocations = allocations.to_a.map { |allocation| normalize(allocation) }
    end

    def call
      validate!
      shares = exact_shares
      distribute_remainder!(shares)
      success(build_allocations(shares))
    end

    private

    attr_reader :allocations, :total_minor

    def normalize(allocation)
      attributes = allocation.to_h
      {
        id: attributes.fetch(:id) { attributes.fetch("id") }.to_s,
        allocation_basis_points: attributes.fetch(:allocation_basis_points) do
          attributes.fetch("allocation_basis_points")
        end
      }
    end

    def validate!
      raise ArgumentError unless total_minor.is_a?(Integer) && total_minor >= 0
      raise ArgumentError if allocations.empty?
      raise ArgumentError unless allocations.map { |allocation| allocation[:id] }.uniq.length == allocations.length
      raise ArgumentError unless allocations.all? { |allocation| valid_share?(allocation) }
      raise ArgumentError unless allocations.sum { |allocation| allocation[:allocation_basis_points] } == BASIS_POINTS
    end

    def valid_share?(allocation)
      id = allocation[:id]
      basis_points = allocation[:allocation_basis_points]
      id.present? && basis_points.is_a?(Integer) && basis_points.positive? && basis_points <= BASIS_POINTS
    end

    def exact_shares
      allocations.map do |allocation|
        exact = Rational(total_minor * allocation[:allocation_basis_points], BASIS_POINTS)
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
  end
end
