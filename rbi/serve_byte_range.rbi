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

  class BlockWritableWithLimit
    # sord omit - no YARD type given for "limit", using untyped
    sig { params(limit: T.untyped, block_that_accepts_writes: T.untyped).void }
    def initialize(limit, &block_that_accepts_writes); end

    # sord omit - no YARD type given for "string", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(string: T.untyped).returns(T.untyped) }
    def write(string); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def verify!; end
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
end
