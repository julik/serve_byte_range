# frozen_string_literal: true

# rbs_inline: enabled

require "digest"

module ServeByteRange
  # A resource composed of several segments glued together - for example, byte ranges of objects
  # in remote storage interleaved with literal strings. A segment can be any object, since its
  # size is given explicitly. A Sequence can also be a segment of another Sequence.
  #
  #     seq = ServeByteRange::Sequence.new
  #     seq.add_segment(s3_object, size: 1024, etag: s3_object.etag)
  #     seq << "Literal text"
  #     ServeByteRange.serve_sequence(env, seq) do |segment, range_in_segment, io|
  #       io.write(segment.is_a?(String) ? segment.byteslice(range_in_segment) : fetch_range(segment, range_in_segment))
  #     end
  class Sequence
    Interval = Struct.new(
      :segment, #: untyped
      :size, #: Integer
      :offset, #: Integer
      :etag, #: String
      :weak #: bool
    )
    private_constant :Interval

    # @rbs @intervals: Array[Interval]
    # @rbs @etag: String?

    # The total size of all segments in bytes
    attr_reader :size #: Integer

    #     @rbs *segments: untyped -- segments to add with `<<`
    def initialize(*segments)
      @intervals = []
      @size = 0
      segments.each { |segment| self << segment }
    end

    # Adds a segment of a given size. Segments of zero size are skipped. The size and ETag are taken
    # as they are now, so a String gets copied and frozen, and a Sequence gets frozen when added.
    #
    # The `etag` goes into the ETag of the Sequence. Without it only the size is known, which won't catch
    # content changes that keep the size the same - so the ETag of the Sequence becomes weak. It can be
    # quoted (as S3 returns it) or not, and a weak one (`W/"..."`) makes the ETag of the Sequence weak too.
    #
    #     @rbs segment: untyped -- any object, it gets yielded back when serving
    #     @rbs size: Integer -- the size of the segment in bytes
    #     @rbs etag: untyped -- a validator for the segment
    #     @rbs return: self
    def add_segment(segment, size:, etag: nil)
      raise ArgumentError, "Segment size must be an Integer >= 0, but was #{size.inspect}" unless size.is_a?(Integer) && size >= 0
      return self if size.zero?
      segment = segment.dup.freeze if segment.is_a?(String) && !segment.frozen?
      segment.freeze if segment.is_a?(Sequence)
      weak = etag.nil? || etag.to_s.start_with?("W/")
      opaque_etag = etag.to_s.delete_prefix("W/").delete_prefix('"').delete_suffix('"')
      @intervals << Interval.new(segment, size, @size, opaque_etag, weak)
      @size += size
      @etag = nil
      self
    end

    # Adds a String (sized in bytes and validated by its contents), a Sequence, an object responding
    # to `bytesize`, or an IO-ish object (responding to `read` and `size`, like File, StringIO or Tempfile).
    # Anything else needs an explicit size, so use #add_segment for it.
    #
    #     @rbs segment: untyped
    #     @rbs return: self
    def <<(segment)
      case segment
      when String
        add_segment(segment, size: segment.bytesize, etag: Digest::SHA1.hexdigest(segment))
      when Sequence
        add_segment(segment, size: segment.size, etag: segment.strong_etag? ? segment.etag : nil)
      else
        # A bare `size` is an element count for an Array or a Hash, so only trust it for IO-ish objects
        size = if segment.respond_to?(:bytesize)
          segment.bytesize
        elsif segment.respond_to?(:read) && segment.respond_to?(:size)
          segment.size
        else
          raise ArgumentError, "Can not tell the size in bytes of a #{segment.class}, use add_segment with an explicit size:"
        end
        add_segment(segment, size: size)
      end
    end

    # A weak ETag stops If-Range from matching, so a client won't splice ranges taken from
    # different versions of a segment whose content has changed but whose size has not
    #
    # Returns a quoted ETag derived from the ETags of all the segments, weak (`W/"..."`)
    # if any segment was added without an `etag:`
    #
    #     @rbs return: String
    def etag
      @etag ||= begin
        # The size goes in too, since the same validator with a different size is a different representation
        digest = '"%s"' % Digest::SHA1.hexdigest(@intervals.map { |iv| "#{iv.size}:#{iv.etag}" }.join("\0"))
        strong_etag? ? digest : "W/#{digest}"
      end
    end

    # Freezes the Sequence, so that no more segments can be added
    #
    #     @rbs return: self
    def freeze
      etag # memoize while we still can
      @intervals.freeze
      super
    end

    # Tells whether every segment has an ETag of its own
    #
    #     @rbs return: bool
    def strong_etag?
      @intervals.none?(&:weak)
    end

    # Yields every segment the range touches, along with the inclusive range of bytes within that segment.
    # Nested Sequences are descended into, so only the leaf segments get yielded.
    #
    # The range must have both ends given, exclusive ranges are fine. The yielded ranges are always inclusive.
    # Returns an Enumerator when called without a block.
    #
    #     @rbs (Range[Integer] range) { (untyped segment, Range[Integer] range_in_segment) -> void } -> void
    #         | (Range[Integer] range) -> Enumerator[[untyped, Range[Integer]], void]
    def each_in_range(range, &blk)
      return enum_for(:each_in_range, range) unless blk
      raise ArgumentError, "The range must have both a beginning and an end, but was #{range.inspect}" if range.begin.nil? || range.end.nil?
      first = range.begin
      last = range.exclude_end? ? range.end - 1 : range.end
      raise ArgumentError, "The range must not be reversed, but was #{range.inspect}" if last < first - 1 # 3...3 is just empty
      return if last < first

      i = @intervals.bsearch_index { |iv| iv.offset + iv.size > first }
      return unless i

      while (iv = @intervals[i]) && iv.offset <= last
        from = [first, iv.offset].max - iv.offset
        to = [last, iv.offset + iv.size - 1].min - iv.offset
        if iv.segment.is_a?(Sequence)
          iv.segment.each_in_range(from..to, &blk)
        else
          yield(iv.segment, from..to)
        end
        i += 1
      end
    end
  end
end
