# frozen_string_literal: true

module Messaging
  # Public balance projection; it intentionally contains derived quantities
  # only, never ledger metadata or payment-provider identifiers.
  class CreditAccountSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :channel, :available, :reserved, :consumed, :released, :refunded

    def available = object.fetch(:available)
    def reserved = object.fetch(:reserved)
    def consumed = object.fetch(:consumed)
    def released = object.fetch(:released)
    def refunded = object.fetch(:refunded)
  end
end
