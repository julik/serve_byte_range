# frozen_string_literal: true

require "rack"
require_relative "serve_byte_range/sequence"

module ServeByteRange
  class BlockWritableWithLimit
    COPY_ON_WRITE_SAFE_WITH_COPY_STREAM = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")
    private_constant :COPY_ON_WRITE_SAFE_WITH_COPY_STREAM

    # Yields a writable which passes the bytes on to `sink`, and makes sure exactly `limit` bytes got written
    #
    # @param limit[Integer] how many bytes have to be written
    # @param sink[#call] receives the written bytes
    # @param label[String,#call] what is being written, for the error messages. Can be a callable
    #   returning the String, so that the String only gets built when there is an error
    # @yield [io[BlockWritableWithLimit]]
    # @return [void]
    def self.write_exactly(limit, sink, label: "range")
      writable = new(limit, label: label, &sink)
      yield(writable)
      writable.verify!
    end

    def initialize(limit, label: "range", &block_that_accepts_writes)
      @limit = limit
      @label = label
      @written = 0
      @block_that_accepts_bytes = block_that_accepts_writes
    end

    def write(string)
      return 0 if string.empty?
      would_have_output = @written + string.bytesize
      raise "You are trying to write more than advertised - #{would_have_output} bytes, the limit for this #{label} is #{@limit}" if @limit < would_have_output
      @written += string.bytesize
      # Only a frozen string can be passed on without copying. IO.copy_stream reuses one buffer for all
      # of its writes, and Rack::ETag and friends hold on to the chunks they get
      binary_string = (string.frozen? && string.encoding == Encoding::BINARY) ? string : binary_copy(string)
      @block_that_accepts_bytes.call(binary_string)
      string.bytesize
    end

    def verify!
      raise "You wrote #{@written} bytes but the #{label} requires #{@limit} bytes" unless @written == @limit
    end

    private

    # `b` and `dup` do not copy the bytes, they share the memory with the original until either gets
    # modified. IO.copy_stream on Ruby 2.7 to 3.1 reads into its buffer without breaking that sharing,
    # so our "copy" got overwritten while the webserver still held on to it. There we have to copy
    # the bytes for real by appending, which may eat memory: every chunk gets duplicated, and so does a
    # huge string written in one go (100MB of `body.read` briefly takes 200MB). Starting with 3.2
    # IO.copy_stream un-shares its buffer before reading into it, so the cheap `b` is safe.
    def binary_copy(string)
      return string.b if COPY_ON_WRITE_SAFE_WITH_COPY_STREAM
      (String.new(capacity: string.bytesize, encoding: Encoding::BINARY) << string).force_encoding(Encoding::BINARY)
    end

    def label
      @label.respond_to?(:call) ? @label.call : @label
    end
  end

  class ByteRangeBody
    def initialize(http_range:, resource_size:, resource_content_type: "binary/octet-stream", &serving_block)
      @http_range = http_range
      @resource_size = resource_size
      @resource_content_type = resource_content_type
      @serving_block = serving_block
    end

    def status
      206
    end

    def each(&blk)
      BlockWritableWithLimit.write_exactly(@http_range.size, blk) { |io| @serving_block.call(@http_range, io) }
    end

    def content_length
      @http_range.size
    end

    def content_type
      @resource_content_type
    end

    def headers
      {
        "Accept-Ranges" => "bytes",
        "Content-Length" => content_length.to_s,
        "Content-Type" => content_type,
        "Content-Range" => "bytes %d-%d/%d" % [@http_range.begin, @http_range.end, @resource_size]
      }
    end
  end

  class EmptyBody
    def status
      200
    end

    def content_length
      0
    end

    def each(&blk)
      # write nothing
    end

    def headers
      {
        "Accept-Ranges" => "bytes",
        "Content-Length" => content_length.to_s
      }
    end
  end

  class NotModifiedBody < EmptyBody
    def status
      304
    end
  end

  class WholeBody < ByteRangeBody
    def initialize(resource_size:, **more, &serving_block)
      super(http_range: Range.new(0, resource_size - 1), resource_size: resource_size, **more, &serving_block)
    end

    def status
      200
    end

    def headers
      super.tap { |hh| hh.delete("Content-Range") }
    end
  end

  class Unsatisfiable < EmptyBody
    def initialize(resource_size:)
      @resource_size = resource_size
    end

    def status
      416
    end

    def headers
      super.tap do |hh|
        hh["Content-Range"] = "bytes */%s" % @resource_size
      end
    end
  end

  # See https://www.ietf.org/archive/id/draft-ietf-httpbis-p5-range-09.html
  class MultipartByteRangesBody < ByteRangeBody
    # @param http_ranges[Array<Range>]
    def initialize(http_ranges:, boundary:, **params_for_single_range, &serving_block)
      super(http_range: http_ranges.first, **params_for_single_range)
      @http_ranges = http_ranges
      @boundary = boundary
    end

    def each(&blk)
      @http_ranges.each_with_index do |range, part_i|
        yield(part_header(range, part_i))
        BlockWritableWithLimit.write_exactly(range.size, blk) { |io| @serving_block.call(range, io) }
      end
      yield(trailer)
    end

    def content_length
      # The Content-Length of a multipart response includes the length
      # of all the ranges of the resource, but also the lengths of the
      # multipart part headers - which we need to precompute. To do it
      # we need to run through all of our ranges and output some strings,
      # and if a lot of ranges are involved this can get expensive. So
      # memoize the envelope size (it never changes between calls)
      @envelope_size ||= compute_envelope_size
    end

    def content_type
      "multipart/byteranges; boundary=#{@boundary}"
    end

    def headers
      super.tap do |hh|
        hh.delete("Content-Range")
      end
    end

    private

    def compute_envelope_size
      @http_ranges.each_with_index.inject(0) do |size_sum, (http_range, part_index)|
        # Generate the header for this multipart part ahead of time - we can do this
        # since we know the boundary and can generate the part headers, without retrieving
        # the actual bytes of the resource
        header_bytes = part_header(http_range, part_index)
        # The amount of output contributed by the part is:
        # size of the header for the part + bytes of the part itself
        part_size = header_bytes.bytesize + http_range.size
        size_sum + part_size
      end + trailer.bytesize # Account for the trailer as well
    end

    def trailer
      "\r\n--%s--\r\n" % @boundary
    end

    def part_header(http_range, part_index)
      [
        (part_index > 0) ? "\r\n" : "", # Parts follwing the first have to be delimited "at the top"
        "--%s\r\n" % @boundary,
        "Content-Type: #{@resource_content_type}\r\n",
        "Content-Range: bytes %d-%d/%d\r\n" % [http_range.begin, http_range.end, @resource_size],
        "\r\n"
      ].join
    end
  end

  # Strictly - the boundary is supposed to not appear in any of the parts of the multipart response, so _first_
  # you need to scan the response, pick a byte sequence that does not occur in it, and then use that. In practice,
  # nobody does that - and a well-behaved HTTP client should honor the Content-Range header when extracting
  # the byte range from the response. See https://stackoverflow.com/questions/37413715
  def self.generate_boundary
    Random.bytes(12).unpack1("H*")
  end

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
  # @param ranges[Array<Range>] an array of inclusive, limited ranges of integers
  # @return [Array] ranges squashed together honoring their overlaps
  def self.coalesce_ranges(ranges)
    return [] if ranges.empty?
    # The RFC says https://www.rfc-editor.org/rfc/rfc7233#section-6.1
    #
    # > Servers ought to ignore, coalesce, or reject
    # > egregious range requests, such as requests for more than two
    # > overlapping ranges or for many small ranges in a single set,
    # > particularly when the ranges are requested out of order for no
    # > apparent reason.
    sorted_ranges = ranges.sort_by(&:begin)
    first = sorted_ranges.shift
    coalesced_sorted_ranges = sorted_ranges.each_with_object([first]) do |next_range, acc|
      prev_range = acc.pop
      if prev_range.end >= next_range.begin # Range#overlap? can be used on 3.3+
        new_begin = [prev_range.begin, next_range.begin].min
        new_end = [prev_range.end, next_range.end].max
        acc << Range.new(new_begin, new_end)
      else
        acc << prev_range << next_range
      end
    end
    # Sort the ranges according to the order the client requested.
    # The spec says that a client _may_ want to get a certain byte range first,
    # and it seems a legitimate use case, not ill intent.
    #
    # > A client that is requesting multiple ranges SHOULD list those ranges
    # > in ascending order (the order in which they would typically be
    # > received in a complete representation) unless there is a specific
    # > need to request a later part earlier.  For example, a user agent
    # > processing a large representation with an internal catalog of parts
    # > might need to request later parts first, particularly if the
    # > representation consists of pages stored in reverse order and the user
    # > agent wishes to transfer one page at a time.
    indices = ranges.map do |r|
      coalesced_sorted_ranges.find_index { |cr| cr.begin <= r.begin && cr.end >= r.end }
    end
    indices.uniq.map { |i| coalesced_sorted_ranges.fetch(i) }
  end

  # Quotes the ETag unless it already is a quoted strong or weak (`W/"..."`) entity tag
  #
  # @param etag[String,nil] the ETag, quoted or not
  # @return [String,nil] the quoted ETag
  def self.quote_etag(etag)
    return if etag.nil?
    etag = etag.to_s
    # A double quote is not allowed inside an entity tag, so stray ones from botched quoting get dropped
    etag.match?(/\A(W\/)?"[^"]*"\z/) ? etag : %("#{etag.delete('"')}")
  end

  # If-Range must use the strong comparison, so a weak ETag never matches.
  # See https://www.rfc-editor.org/rfc/rfc9110#section-13.1.5
  #
  # @param header_value[String] the value of the If-Range header
  # @param etag[String,nil] the quoted current ETag
  # @return [Boolean]
  def self.strong_etag_match?(header_value, etag)
    return false if etag.nil? || etag.start_with?("W/")
    header_value.strip == etag
  end

  # If-None-Match is `*` or a list of entity tags, compared with the weak comparison.
  # See https://www.rfc-editor.org/rfc/rfc9110#section-13.1.2
  #
  # @param header_value[String] the value of the If-None-Match header
  # @param etag[String,nil] the quoted current ETag
  # @return [Boolean]
  def self.weak_etag_match?(header_value, etag)
    return true if header_value.strip == "*" # we always have a representation
    return false if etag.nil?
    opaque_tag = etag.delete_prefix("W/")
    # Scan instead of splitting on commas, since a comma is allowed inside an entity tag
    header_value.scan(/(?:W\/)?"[^"]*"/).any? { |tag| tag.delete_prefix("W/") == opaque_tag }
  end

  # @param env[Hash] the Rack env
  # @param resource_size[Integer] the size of the complete resource in bytes
  # @param etag[String,nil] the current ETag of the resource, or nil if none
  # @param resource_content_type[String] the MIME type string of the resource
  # @param multipart_boundary[String] The string to use as multipart boundary. Default is an automatically generated pseudo-random string.
  # @yield [range[Range], io[IO]] The HTTP range being requested and the IO(ish) object to `write()` the bytes into
  # @example
  #     status, headers, body = serve_ranges(env, resource_size: file.size) do |range, io|
  #       file.seek(range.begin)
  #       IO.copy_stream(file, io, range.size)
  #     end
  #     [status, headers, body]
  # @return [Array] the Rack response triplet of `[status, header_hash, enumerable_body]`
  def self.serve_ranges(env, resource_size:, etag: nil, resource_content_type: "binary/octet-stream", multipart_boundary: generate_boundary, &range_serving_block)
    etag = quote_etag(etag)

    # As per RFC:
    # If the entity tag given in the If-Range header matches the current cache validator for the entity,
    # then the server SHOULD provide the specified sub-range of the entity using a 206 (Partial Content)
    # response. If the cache validator does not match, then the server SHOULD return the entire entity
    # using a 200 (OK) response.
    wants_ranges_and_etag_valid = env["HTTP_IF_RANGE"] && strong_etag_match?(env["HTTP_IF_RANGE"], etag) && env["HTTP_RANGE"]
    wants_ranges_and_no_etag = !env["HTTP_IF_RANGE"] && env["HTTP_RANGE"]

    # Very old Rack versions do not have get_byte_ranges and have just byte_ranges
    http_ranges_from_header = Rack::Utils.respond_to?(:get_byte_ranges) ? Rack::Utils.get_byte_ranges(env["HTTP_RANGE"], resource_size) : Rack::Utils.byte_ranges(env, resource_size)
    http_ranges_from_header = coalesce_ranges(http_ranges_from_header) if http_ranges_from_header

    # If-None-Match gets evaluated before Range, and a match means there is nothing to send
    # at all - see https://www.rfc-editor.org/rfc/rfc9110#section-13.2.2
    body = if env["HTTP_IF_NONE_MATCH"] && weak_etag_match?(env["HTTP_IF_NONE_MATCH"], etag)
      NotModifiedBody.new
    elsif resource_size.zero?
      EmptyBody.new
    elsif http_ranges_from_header && (wants_ranges_and_no_etag || wants_ranges_and_etag_valid)
      if http_ranges_from_header.none?
        Unsatisfiable.new(resource_size: resource_size)
      elsif http_ranges_from_header.one?
        ByteRangeBody.new(http_range: http_ranges_from_header.first, resource_size: resource_size, resource_content_type: resource_content_type, &range_serving_block)
      else
        MultipartByteRangesBody.new(http_ranges: http_ranges_from_header, resource_size: resource_size, resource_content_type: resource_content_type, boundary: multipart_boundary, &range_serving_block)
      end
    else
      WholeBody.new(resource_size: resource_size, resource_content_type: resource_content_type, &range_serving_block)
    end
    headers = body.headers
    headers["ETag"] = etag if etag

    [body.status, headers, body]
  end

  # Serves a {Sequence}, yielding every segment that a requested range touches. Writes for every
  # segment are checked against the size of the range within that segment.
  #
  # @param env[Hash] the Rack env
  # @param sequence[Sequence] the Sequence to serve
  # @param etag[String,nil] the ETag of the resource, defaults to the ETag of the Sequence. Pass nil to not send one
  # @param options[Hash] other options for {serve_ranges}
  # @yield [segment[Object], range_in_segment[Range], io[IO]] The segment, the range of bytes within it, and the IO(ish) object to `write()` those bytes into
  # @return [Array] the Rack response triplet of `[status, header_hash, enumerable_body]`
  def self.serve_sequence(env, sequence, etag: sequence.etag, **options, &segment_serving_block)
    serve_ranges(env, resource_size: sequence.size, etag: etag, **options) do |range, io|
      sequence.each_in_range(range) do |segment, range_in_segment|
        label = -> { "segment (#{segment.class}, bytes #{range_in_segment.begin}-#{range_in_segment.end} of it)" }
        BlockWritableWithLimit.write_exactly(range_in_segment.size, io.method(:write), label: label) do |segment_io|
          segment_serving_block.call(segment, range_in_segment, segment_io)
        end
      end
    end
  end
end
