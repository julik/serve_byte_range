# frozen_string_literal: true

require_relative "byte_comparator"

module BytesAssertions
  def assert_same_bytes(expected, actual, message = nil)
    comparator = ByteComparator.new(expected, actual)
    assert(comparator.same?, -> { [message, comparator.describe_difference].compact.join("\n") })
  end
end
