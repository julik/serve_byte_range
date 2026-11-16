# frozen_string_literal: true

require "bundler"
Bundler.setup

require "minitest"
require "minitest/autorun"
require_relative "support/bytes_assertions"

class ByteComparatorTest < Minitest::Test
  include BytesAssertions

  def test_passes_for_same_bytes_in_different_encodings
    assert_same_bytes "é", "é".b
  end

  def test_describes_first_difference
    expected = "0123456789abcdef".b
    actual = "0123456789abXdef".b
    error = assert_raises(Minitest::Assertion) { assert_same_bytes(expected, actual) }
    assert_includes error.message, "Bytes differ (expected 16 bytes, got 16)"
    assert_includes error.message, "diff at offset 12,"
    assert_includes error.message, "should have been [0x63 0x64 0x65 0x66]"
    assert_includes error.message, "but was [0x58 0x64 0x65 0x66]"
  end

  def test_describes_truncation_and_differences_past_the_first_block
    expected = ("a" * 5000 + "bc").b
    error = assert_raises(Minitest::Assertion) { assert_same_bytes(expected, "a" * 5000, "Custom") }
    assert error.message.start_with?("Custom\n")
    assert_includes error.message, "at offset 5000,"
    assert_includes error.message, "should have been [0x62 0x63]"
    assert_includes error.message, "but was [empty]"

    error = assert_raises(Minitest::Assertion) { assert_same_bytes("", "x") }
    assert_includes error.message, "diff at offset 0,"
  end

  def test_comparator_reports_offset_and_nothing_for_same_bytes
    assert_nil ByteComparator.new("abc", "abc".b).first_difference_offset
    assert_nil ByteComparator.new("abc", "abc").describe_difference
    assert_equal 2, ByteComparator.new("abc", "abd").first_difference_offset
    assert_equal 3, ByteComparator.new("abc", "abcd").first_difference_offset
    assert_equal 5000, ByteComparator.new("a" * 6000, "a" * 5000 + "b" * 1000).first_difference_offset
  end
end
