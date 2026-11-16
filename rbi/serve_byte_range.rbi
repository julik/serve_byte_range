# typed: strong
module ServeByteRange
  VERSION = T.let("1.0.0", T.untyped)

  # sord omit - no YARD return type given, using untyped
  # Strictly - the boundary is supposed to not appear in any of the parts of the multipart response, so _first_
  # you need to scan the response, pick a byte sequence that does not occur in it, and then use that. In practice,
  # nobody does that - and a well-behaved HTTP client should honor the Content-Range header when extracting
  # the byte range from the response. See https://stackoverflow.com/questions/37413715
  sig { returns(T.untyped) }
  def self.generate_boundary; end

  # The RFC specifically gives an example of non-canonical, but still
  # valid request for overlapping ranges:
  #   > Several legal but not canonical specifications of the second 500
  #   > bytes (byte offsets 500-999, inclusive):
  #   >  bytes=500-600,601-999
  #   >  bytes=500-700,601-999
  # In such cases, ranges need to be collapsed together. First, to avoid serving
  # a tiny byte range over and over - causing excessive requests to upstream,
  # second - to optimize for doing less requests in total.
  # 
  # _@param_ `ranges` — an array of inclusive, limited ranges of integers
  # 
  # _@return_ — ranges squashed together honoring their overlaps
  sig { params(ranges: T::Array[T::Range[T.untyped]]).returns(T::Array[T.untyped]) }
  def self.coalesce_ranges(ranges); end

  # Quotes the ETag unless it already is a quoted strong or weak (`W/"..."`) entity tag
  # 
  # _@param_ `etag` — the ETag, quoted or not
  # 
  # _@return_ — the quoted ETag
  sig { params(etag: T.nilable(String)).returns(T.nilable(String)) }
  def self.quote_etag(etag); end

  # If-Range must use the strong comparison, so a weak ETag never matches.
  # See https://www.rfc-editor.org/rfc/rfc9110#section-13.1.5
  # 
  # _@param_ `header_value` — the value of the If-Range header
  # 
  # _@param_ `etag` — the quoted current ETag
  sig { params(header_value: String, etag: T.nilable(String)).returns(T::Boolean) }
  def self.strong_etag_match?(header_value, etag); end

  # If-None-Match is `*` or a list of entity tags, compared with the weak comparison.
  # See https://www.rfc-editor.org/rfc/rfc9110#section-13.1.2
  # 
  # _@param_ `header_value` — the value of the If-None-Match header
  # 
  # _@param_ `etag` — the quoted current ETag
  sig { params(header_value: String, etag: T.nilable(String)).returns(T::Boolean) }
  def self.weak_etag_match?(header_value, etag); end

  # _@param_ `env` — the Rack env
  # 
  # _@param_ `resource_size` — the size of the complete resource in bytes
  # 
  # _@param_ `etag` — the current ETag of the resource, or nil if none
  # 
  # _@param_ `resource_content_type` — the MIME type string of the resource
  # 
  # _@param_ `multipart_boundary` — The string to use as multipart boundary. Default is an automatically generated pseudo-random string.
  # 
  # _@return_ — the Rack response triplet of `[status, header_hash, enumerable_body]`
  # 
  # ```ruby
  # status, headers, body = serve_ranges(env, resource_size: file.size) do |range, io|
  #   file.seek(range.begin)
  #   IO.copy_stream(file, io, range.size)
  # end
  # [status, headers, body]
  # ```
  sig do
    params(
      env: T::Hash[T.untyped, T.untyped],
      resource_size: Integer,
      etag: T.nilable(String),
      resource_content_type: String,
      multipart_boundary: String,
      range_serving_block: T.untyped
    ).returns(T::Array[T.untyped])
  end
  def self.serve_ranges(env, resource_size:, etag: nil, resource_content_type: "binary/octet-stream", multipart_boundary: generate_boundary, &range_serving_block); end

  # Serves a {Sequence}, yielding every segment that a requested range touches. Writes for every
  # segment are checked against the size of the range within that segment.
  # 
  # _@param_ `env` — the Rack env
  # 
  # _@param_ `sequence` — the Sequence to serve
  # 
  # _@param_ `etag` — the ETag of the resource, defaults to the ETag of the Sequence
  # 
  # _@param_ `options` — other options for {serve_ranges}
  # 
  # _@return_ — the Rack response triplet of `[status, header_hash, enumerable_body]`
  sig do
    params(
      env: T::Hash[T.untyped, T.untyped],
      sequence: Sequence,
      etag: String,
      options: T::Hash[T.untyped, T.untyped],
      segment_serving_block: T.untyped
    ).returns(T::Array[T.untyped])
  end
  def self.serve_sequence(env, sequence, etag: sequence.etag, **options, &segment_serving_block); end

  class BlockWritableWithLimit
    # sord duck - #call looks like a duck type, replacing with untyped
    # sord duck - #call looks like a duck type, replacing with untyped
    # Yields a writable which passes the bytes on to `sink`, and makes sure exactly `limit` bytes got written
    # 
    # _@param_ `limit` — how many bytes have to be written
    # 
    # _@param_ `sink` — receives the written bytes
    # 
    # _@param_ `label` — what is being written, for the error messages. Can be a callable returning the String, so that the String only gets built when there is an error
    sig { params(limit: Integer, sink: T.untyped, label: T.any(String, T.untyped)).void }
    def self.write_exactly(limit, sink, label: "range"); end

    # sord omit - no YARD type given for "limit", using untyped
    # sord omit - no YARD type given for "label:", using untyped
    sig { params(limit: T.untyped, label: T.untyped, block_that_accepts_writes: T.untyped).void }
    def initialize(limit, label: "range", &block_that_accepts_writes); end

    # sord omit - no YARD type given for "string", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(string: T.untyped).returns(T.untyped) }
    def write(string); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def verify!; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def label; end
  end

  class ByteRangeBody
    # sord omit - no YARD type given for "http_range:", using untyped
    # sord omit - no YARD type given for "resource_size:", using untyped
    # sord omit - no YARD type given for "resource_content_type:", using untyped
    sig do
      params(
        http_range: T.untyped,
        resource_size: T.untyped,
        resource_content_type: T.untyped,
        serving_block: T.untyped
      ).void
    end
    def initialize(http_range:, resource_size:, resource_content_type: "binary/octet-stream", &serving_block); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def status; end

    # sord omit - no YARD return type given, using untyped
    sig { params(blk: T.untyped).returns(T.untyped) }
    def each(&blk); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def content_length; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def content_type; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def headers; end
  end

  class EmptyBody
    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def status; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def content_length; end

    # sord omit - no YARD return type given, using untyped
    sig { params(blk: T.untyped).returns(T.untyped) }
    def each(&blk); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def headers; end
  end

  class NotModifiedBody < ServeByteRange::EmptyBody
    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def status; end
  end

  class WholeBody < ServeByteRange::ByteRangeBody
    # sord omit - no YARD type given for "resource_size:", using untyped
    # sord omit - no YARD type given for "**more", using untyped
    sig { params(resource_size: T.untyped, more: T.untyped, serving_block: T.untyped).void }
    def initialize(resource_size:, **more, &serving_block); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def status; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def headers; end
  end

  class Unsatisfiable < ServeByteRange::EmptyBody
    # sord omit - no YARD type given for "resource_size:", using untyped
    sig { params(resource_size: T.untyped).void }
    def initialize(resource_size:); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def status; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def headers; end
  end

  # See https://www.ietf.org/archive/id/draft-ietf-httpbis-p5-range-09.html
  class MultipartByteRangesBody < ServeByteRange::ByteRangeBody
    # sord omit - no YARD type given for "boundary:", using untyped
    # sord omit - no YARD type given for "**params_for_single_range", using untyped
    # _@param_ `http_ranges`
    sig do
      params(
        http_ranges: T::Array[T::Range[T.untyped]],
        boundary: T.untyped,
        params_for_single_range: T.untyped,
        serving_block: T.untyped
      ).void
    end
    def initialize(http_ranges:, boundary:, **params_for_single_range, &serving_block); end

    # sord omit - no YARD return type given, using untyped
    sig { params(blk: T.untyped).returns(T.untyped) }
    def each(&blk); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def content_length; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def content_type; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def headers; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def compute_envelope_size; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def trailer; end

    # sord omit - no YARD type given for "http_range", using untyped
    # sord omit - no YARD type given for "part_index", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(http_range: T.untyped, part_index: T.untyped).returns(T.untyped) }
    def part_header(http_range, part_index); end
  end

  # A resource composed of several segments glued together - for example, byte ranges of objects
  # in remote storage interleaved with literal strings. A segment can be any object, since its
  # size is given explicitly. A Sequence can also be a segment of another Sequence.
  # 
  # @example
  #     seq = ServeByteRange::Sequence.new
  #     seq.add_segment(s3_object, size: 1024, etag: s3_object.etag)
  #     seq << "Literal text"
  #     ServeByteRange.serve_sequence(env, seq) do |segment, range_in_segment, io|
  #       io.write(segment.is_a?(String) ? segment.byteslice(range_in_segment) : fetch_range(segment, range_in_segment))
  #     end
  class Sequence
    # _@param_ `segments` — segments to add with `<<`
    sig { params(segments: T::Array[T.untyped]).void }
    def initialize(*segments); end

    # Adds a segment of a given size. Segments of zero size are skipped.
    # 
    # _@param_ `segment` — any object, it gets yielded back when serving
    # 
    # _@param_ `size` — the size of the segment in bytes
    # 
    # _@param_ `etag` — a validator for the segment, which goes into the ETag of the Sequence. Without it only the size is known, which won't catch content changes that keep the size the same - so the ETag of the Sequence becomes weak.
    sig { params(segment: Object, size: Integer, etag: T.nilable(T.any(String, Integer))).returns(T.self_type) }
    def add_segment(segment, size:, etag: nil); end

    # Adds a String (sized in bytes and validated by its contents), a Sequence, an object responding
    # to `bytesize`, or an IO-ish object (responding to `read` and `size`, like File, StringIO or Tempfile).
    # Anything else needs an explicit size, so use {#add_segment} for it.
    # 
    # _@param_ `segment`
    sig { params(segment: T.any(String, Sequence, Object)).returns(T.self_type) }
    def <<(segment); end

    # A weak ETag stops If-Range from matching, so a client won't splice ranges taken from
    # different versions of a segment whose content has changed but whose size has not
    # 
    # _@return_ — a quoted ETag derived from the ETags of all the segments, weak (`W/"..."`)
    # if any segment was added without an `etag:`
    sig { returns(String) }
    def etag; end

    # _@return_ — whether every segment has an ETag of its own
    sig { returns(T::Boolean) }
    def strong_etag?; end

    # Yields every segment the range touches, along with the inclusive range of bytes within that segment.
    # Nested Sequences are descended into, so only the leaf segments get yielded.
    # 
    # _@param_ `range` — an inclusive range of bytes within the Sequence
    sig { params(range: T::Range[T.untyped], blk: T.untyped).void }
    def each_in_range(range, &blk); end

    # _@return_ — the total size of all segments in bytes
    sig { returns(Integer) }
    attr_reader :size

    class Interval < Struct
      # Returns the value of attribute segment
      sig { returns(Object) }
      attr_accessor :segment

      # Returns the value of attribute size
      sig { returns(Object) }
      attr_accessor :size

      # Returns the value of attribute offset
      sig { returns(Object) }
      attr_accessor :offset

      # Returns the value of attribute etag
      sig { returns(Object) }
      attr_accessor :etag

      # Returns the value of attribute weak
      sig { returns(Object) }
      attr_accessor :weak
    end
  end
end
