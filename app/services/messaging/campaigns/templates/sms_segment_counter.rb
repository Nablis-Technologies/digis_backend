# frozen_string_literal: true

module Messaging
  module Campaigns
    module Templates
      # Calculates provider-billed SMS segments without treating Ruby codepoints
      # as wire units. GSM-7 counts septets; Unicode counts UTF-16 code units.
      module SmsSegmentCounter
        GSM7_BASIC = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà".chars.freeze
        GSM7_EXTENSION = "^{}\\[~]|€".chars.freeze
        ALLOWED_CONTROL_CHARACTERS = [ "\n", "\r", "\t" ].freeze

        module_function

        def call(body)
          text = body.to_s
          raise ArgumentError, I18n.t("messaging.errors.campaign_sms_body_blank") if text.blank?
          if unsupported_control?(text)
            raise ArgumentError, I18n.t("messaging.errors.campaign_sms_body_control_character")
          end

          gsm7?(text) ? gsm7_segments(text) : unicode_segments(text)
        end

        def units_for(channel:, body:)
          channel.to_s.strip.downcase == "email" ? 1 : call(body)
        end

        def gsm7?(text)
          text.each_char.all? { |character| GSM7_BASIC.include?(character) || GSM7_EXTENSION.include?(character) }
        end

        def gsm7_segments(text)
          septets = text.each_char.sum { |character| GSM7_EXTENSION.include?(character) ? 2 : 1 }
          septets <= 160 ? 1 : (septets.to_f / 153).ceil
        end

        def unicode_segments(text)
          units = text.encode("UTF-16BE").bytesize / 2
          units <= 70 ? 1 : (units.to_f / 67).ceil
        end

        def unsupported_control?(text)
          text.each_char.any? do |character|
            character.ord < 0x20 && !ALLOWED_CONTROL_CHARACTERS.include?(character)
          end
        end
      end
    end
  end
end
