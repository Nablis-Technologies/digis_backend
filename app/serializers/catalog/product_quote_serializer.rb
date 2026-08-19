# frozen_string_literal: true

class Catalog::ProductQuoteSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :product_id, :charge_currency, :amount_minor, :source_type,
             :from_currency, :exchange_rate_id, :exchange_rate_value, :at,
             :stream_access_protection, :stream_access_notice_code

  def stream_access_protection
    stream_access&.required_access_protection
  end

  def stream_access_notice_code
    protection = stream_access_protection
    return if protection.blank?
    return "soft_gated_youtube_link_sharing" if protection == "soft_gated" && stream_provider == "youtube"
    return "public_stream" if protection == "public"
    return "signed_provider_enforced" if protection == "signed"

    nil
  end

  def read_attribute_for_serialization(attr)
    return public_send(attr) if respond_to?(attr)

    object.public_send(attr)
  end

  private

  def product
    instance_options[:product]
  end

  def stream_access
    product&.product_accesses&.find(&:stream?)
  end

  def stream_provider
    stream_access&.event_date&.event_stream&.provider
  end
end
