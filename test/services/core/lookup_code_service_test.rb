# frozen_string_literal: true

require "test_helper"

module Core
  class LookupCodeServiceTest < ActiveSupport::TestCase
    test "generates and validates an eight-character event-scoped code" do
      code = Core::LookupCodeService.generate(events_events(:ready_listing).id)

      assert_match(/\A[23456789CFGHJKMNPQRVWX]{8}\z/, code)
      assert_equal code, Core::LookupCodeService.validate(code)
    end

    test "rejects malformed and checksum-invalid codes" do
      event_id = events_events(:ready_listing).id
      code = Core::LookupCodeService.generate(event_id)
      invalid_checksum = code.dup
      invalid_checksum[-1] = Core::LookupCodeService::ALPHABET.find { |character| character != code[-1] }

      assert_nil Core::LookupCodeService.validate(invalid_checksum)
      assert_nil Core::LookupCodeService.validate("not-a-code")
    end
  end
end
