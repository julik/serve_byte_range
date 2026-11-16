# frozen_string_literal: true

# Compares two strings byte for byte, and describes where they differ - showing the offset and
# what the bytes there should have been - instead of a diff of a binary blob
class ByteComparator
  CONTEXT_BYTES = 8
  BLOCK_SIZE = 4096

  def initialize(expected, actual)
    @expected = expected.b
    @actual = actual.b
  end

  def same?
    @expected == @actual
  end

  # @return [Integer,nil] the offset of the first differing byte, or nil if the strings are the same
  def first_difference_offset
    return if same?
    common = [@expected.bytesize, @actual.bytesize].min
    # Skip over equal blocks first, comparing byte by byte over 100KB+ strings is slow-ish
    offset = 0
    offset += BLOCK_SIZE while offset + BLOCK_SIZE <= common && @expected.byteslice(offset, BLOCK_SIZE) == @actual.byteslice(offset, BLOCK_SIZE)
    offset += 1 while offset < common && @expected.getbyte(offset) == @actual.getbyte(offset)
    offset
  end

  # @return [String,nil] the description of the difference, or nil if the strings are the same
  def describe_difference
    offset = first_difference_offset
    return unless offset
    [
      (@expected.bytesize == @actual.bytesize) ? "Bytes differ" : "Bytes differ (expected #{@expected.bytesize} bytes, got #{@actual.bytesize})",
      "diff at offset #{offset},",
      "should have been #{format_bytes(@expected.byteslice(offset, CONTEXT_BYTES))}",
      "but was #{format_bytes(@actual.byteslice(offset, CONTEXT_BYTES))}"
    ].join("\n")
  end

  private

  def format_bytes(bytes)
    return "[empty]" if bytes.nil? || bytes.empty?
    "[" + bytes.unpack("C*").map { |b| "0x%02X" % b }.join(" ") + "]"
  end
end
