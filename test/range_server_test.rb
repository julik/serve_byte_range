# frozen_string_literal: true

require "bundler"
Bundler.setup

require_relative "../lib/serve_byte_range"
require "minitest"
require "minitest/autorun"
require_relative "support/bytes_assertions"
require "tempfile"

class ServeByteRangeTest < Minitest::Test
  include BytesAssertions

  def test_serves_whole_body
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", resource_content_type: "x-foo/ba", &serve_proc)

    assert_equal 200, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "474", "Content-Type" => "x-foo/ba", "ETag" => "\"AbCehZ\""}, headers)

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes, output.string
  end

  def test_serves_single_range
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=1-2"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", resource_content_type: "x-foo/ba", &serve_proc)

    assert_equal 206, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "2", "Content-Range" => "bytes 1-2/474", "Content-Type" => "x-foo/ba", "ETag" => "\"AbCehZ\""}, headers)

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes[1..2], output.string

    env = {"HTTP_RANGE" => "bytes=319-"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", resource_content_type: "x-foo/ba", &serve_proc)

    assert_equal 206, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "155", "Content-Range" => "bytes 319-473/474", "Content-Type" => "x-foo/ba", "ETag" => "\"AbCehZ\""}, headers)

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes[319..], output.string

    env = {"HTTP_RANGE" => "bytes=0-0"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", resource_content_type: "x-foo/ba", &serve_proc)

    assert_equal 206, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "1", "Content-Range" => "bytes 0-0/474", "Content-Type" => "x-foo/ba", "ETag" => "\"AbCehZ\""}, headers)

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes[0..0], output.string
  end

  def test_serves_single_range_of_same_range_supplied_multiple_times_just_once
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=1-2,1-2,1-2,1-2"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", resource_content_type: "x-foo/ba", &serve_proc)

    assert_equal 206, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "2", "Content-Range" => "bytes 1-2/474", "Content-Type" => "x-foo/ba", "ETag" => "\"AbCehZ\""}, headers)

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes[1..2], output.string
  end

  def test_unions_overlapping_ranges
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=1-2,2-8,4-9"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", resource_content_type: "x-foo/ba", &serve_proc)

    assert_equal 206, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "9", "Content-Range" => "bytes 1-9/474", "Content-Type" => "x-foo/ba", "ETag" => "\"AbCehZ\""}, headers)

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes[1..9], output.string
  end

  def test_serves_multiple_ranges
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=1-2,4-9,472-"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", multipart_boundary: "azuleju", resource_content_type: "x-foo/bar", &serve_proc)

    assert_equal 206, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "237", "Content-Type" => "multipart/byteranges; boundary=azuleju", "ETag" => "\"AbCehZ\""}, headers)

    reference_lines = [
      "--azuleju",
      "Content-Type: x-foo/bar",
      "Content-Range: bytes 1-2/474",
      "",
      bytes[1..2],
      "--azuleju",
      "Content-Type: x-foo/bar",
      "Content-Range: bytes 4-9/474",
      "",
      bytes[4..9],
      "--azuleju",
      "Content-Type: x-foo/bar",
      "Content-Range: bytes 472-473/474",
      "",
      bytes[472..473],
      "--azuleju--"
    ]

    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    lines = output.string.split("\r\n")

    assert_equal reference_lines, lines
  end

  def test_serves_not_modified_with_just_an_if_none_match
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_IF_NONE_MATCH" => "\"woof\""}
    status, headers, _ = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "\"woof\"", resource_content_type: "x-foo/bar", &serve_proc)

    assert_equal 304, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "0", "ETag" => "\"woof\""}, headers)
  end

  def test_serves_entire_document_on_if_range_header_mismatch
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=1-2,4-9,472-", "HTTP_IF_RANGE" => "\"v2\""}
    status, headers, _ = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "\"v3\"", multipart_boundary: "azuleju", resource_content_type: "x-foo/bar", &serve_proc)

    assert_equal 200, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "474", "Content-Type" => "x-foo/bar", "ETag" => "\"v3\""}, headers)
  end

  def test_generates_boundary_for_multiple_ranges
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=1-2,4-9,472-"}
    status, headers, _ = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", &serve_proc)

    assert_equal 206, status
    assert_equal "335", headers["Content-Length"]
    assert headers["Content-Type"].start_with?("multipart/byteranges; boundary=")
  end

  def test_refuses_invalid_range
    rng = Random.new(Minitest.seed)
    bytes = rng.bytes(474)
    serve_proc = ->(range, io) {
      io.write(bytes[range])
    }

    env = {"HTTP_RANGE" => "bytes=474-"}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "AbCehZ", multipart_boundary: "azuleju", resource_content_type: "x-foo/bar", &serve_proc)

    assert_equal 416, status
    assert_equal({"Accept-Ranges" => "bytes", "Content-Length" => "0", "ETag" => "\"AbCehZ\"", "Content-Range" => "bytes */474"}, headers)

    body.each { |chunk| raise "Should never be called" }
  end

  def test_coalesce_ranges
    assert_equal [], ServeByteRange.coalesce_ranges([])

    ranges = [1..1]
    assert_equal [1..1], ServeByteRange.coalesce_ranges(ranges)

    ranges = [0..0, 0..0, 145..900, 1..12, 3..78, 0..8].shuffle(random: Random.new(Minitest.seed))
    assert_equal [0..78, 145..900], ServeByteRange.coalesce_ranges(ranges).sort_by(&:begin)

    ordered_ranges = [14..32, 0..0, 145..900, 5..16, 4..4]
    # Ordering should be maintained (roughly) in the coalesced ranges
    assert_equal [5..32, 0..0, 145..900, 4..4], ServeByteRange.coalesce_ranges(ordered_ranges)
  end

  def test_quote_etag
    assert_nil ServeByteRange.quote_etag(nil)
    assert_equal '"abc"', ServeByteRange.quote_etag("abc")
    assert_equal '"abc"', ServeByteRange.quote_etag('"abc"')
    assert_equal 'W/"abc"', ServeByteRange.quote_etag('W/"abc"')
    assert_equal '"abc"', ServeByteRange.quote_etag('"abc')
    assert_equal '"abc"', ServeByteRange.quote_etag('abc"')
    assert_equal '"abc"', ServeByteRange.quote_etag('"a"bc"')
  end

  def test_serves_weak_etag_as_is
    status, headers, _ = ServeByteRange.serve_ranges({}, resource_size: 10, etag: 'W/"abc"') { |range, io| io.write("x" * range.size) }
    assert_equal 200, status
    assert_equal 'W/"abc"', headers["ETag"]
  end

  def test_honors_if_range_with_the_etag_it_sent_when_given_unquoted_etag
    bytes = Random.new(Minitest.seed).bytes(474)
    serve_proc = ->(range, io) { io.write(bytes[range]) }

    _, headers, _ = ServeByteRange.serve_ranges({}, resource_size: bytes.bytesize, etag: "abc", &serve_proc)
    assert_equal '"abc"', headers["ETag"]

    env = {"HTTP_RANGE" => "bytes=0-9", "HTTP_IF_RANGE" => headers["ETag"]}
    status, headers, body = ServeByteRange.serve_ranges(env, resource_size: bytes.bytesize, etag: "abc", &serve_proc)
    assert_equal 206, status
    assert_equal "bytes 0-9/474", headers["Content-Range"]
    output = StringIO.new.binmode
    body.each { |chunk| output.write(chunk) }
    assert_same_bytes bytes[0..9], output.string
  end

  def test_honors_if_none_match_with_the_etag_it_sent_when_given_unquoted_etag
    env = {"HTTP_IF_NONE_MATCH" => '"abc"'}
    status, headers, _ = ServeByteRange.serve_ranges(env, resource_size: 10, etag: "abc") { |range, io| io.write("x" * range.size) }
    assert_equal 304, status
    assert_equal '"abc"', headers["ETag"]
  end

  def test_serves_entire_document_on_if_range_with_weak_etag
    env = {"HTTP_RANGE" => "bytes=0-1", "HTTP_IF_RANGE" => 'W/"abc"'}
    status, _, _ = ServeByteRange.serve_ranges(env, resource_size: 10, etag: 'W/"abc"') { |range, io| io.write("x" * range.size) }
    assert_equal 200, status # If-Range requires a strong match
  end

  def test_serves_not_modified_on_weakly_matching_if_none_match
    ['"abc"', 'W/"abc"', '"x", "abc"', '"x",W/"abc"', "*", '"a,b", "abc"'].each do |if_none_match|
      status, headers, _ = ServeByteRange.serve_ranges({"HTTP_IF_NONE_MATCH" => if_none_match}, resource_size: 10, etag: "abc") { |range, io| io.write("x" * range.size) }
      assert_equal 304, status, "Expected 304 for If-None-Match: #{if_none_match}"
      assert_equal '"abc"', headers["ETag"]
    end

    status, _, _ = ServeByteRange.serve_ranges({"HTTP_IF_NONE_MATCH" => '"abc"'}, resource_size: 10, etag: 'W/"abc"') { |range, io| io.write("x" * range.size) }
    assert_equal 304, status # weak comparison ignores W/ on our side too
  end

  def test_serves_whole_body_on_mismatching_if_none_match
    ['"abcd"', 'W/"ab"', '"x", "y"', '"a,b"', "abc", ""].each do |if_none_match|
      status, _, _ = ServeByteRange.serve_ranges({"HTTP_IF_NONE_MATCH" => if_none_match}, resource_size: 10, etag: "abc") { |range, io| io.write("x" * range.size) }
      assert_equal 200, status, "Expected 200 for If-None-Match: #{if_none_match}"
    end

    status, _, _ = ServeByteRange.serve_ranges({"HTTP_IF_NONE_MATCH" => '"abc"'}, resource_size: 10) { |range, io| io.write("x" * range.size) }
    assert_equal 200, status
  end

  def test_serves_not_modified_on_if_none_match_star_without_etag
    status, headers, _ = ServeByteRange.serve_ranges({"HTTP_IF_NONE_MATCH" => "*"}, resource_size: 10) { |range, io| io.write("x" * range.size) }
    assert_equal 304, status
    refute headers.key?("ETag")
  end

  def test_passes_only_frozen_binary_strings_through_without_copying
    yielded = []
    writable = ServeByteRange::BlockWritableWithLimit.new(12) { |chunk| yielded << chunk }
    frozen_binary = "abcd".b.freeze
    binary_buffer = "efgh".b
    utf8 = "éé"
    [frozen_binary, binary_buffer, utf8].each { |str| writable.write(str) }
    writable.verify!

    assert_same frozen_binary, yielded[0]
    refute_same binary_buffer, yielded[1] # a reused buffer, as in IO.copy_stream, must get copied
    refute_same utf8, yielded[2]
    assert yielded.all? { |chunk| chunk.encoding == Encoding::BINARY }
    assert_equal Encoding::UTF_8, utf8.encoding
  end

  def test_chunks_from_copy_stream_survive_being_retained
    bytes = Random.new(Minitest.seed).bytes(100_000)
    source = Tempfile.new("source", binmode: true)
    source.write(bytes)
    source.flush
    _, _, body = ServeByteRange.serve_ranges({}, resource_size: bytes.bytesize) { |range, io| IO.copy_stream(source, io, range.size, range.begin) }
    retained = []
    body.each { |chunk| retained << chunk } # what Rack::ETag does
    assert_same_bytes bytes, retained.join
  end

  def test_serves_not_modified_on_matching_if_none_match_even_with_a_range
    env = {"HTTP_RANGE" => "bytes=0-1", "HTTP_IF_NONE_MATCH" => '"abc"'}
    status, _, _ = ServeByteRange.serve_ranges(env, resource_size: 10, etag: "abc") { |range, io| io.write("x" * range.size) }
    assert_equal 304, status

    env = {"HTTP_RANGE" => "bytes=0-1", "HTTP_IF_RANGE" => '"abc"', "HTTP_IF_NONE_MATCH" => '"abc"'}
    status, _, _ = ServeByteRange.serve_ranges(env, resource_size: 10, etag: "abc") { |range, io| io.write("x" * range.size) }
    assert_equal 304, status

    env = {"HTTP_RANGE" => "bytes=0-1", "HTTP_IF_NONE_MATCH" => '"old"'}
    status, _, _ = ServeByteRange.serve_ranges(env, resource_size: 10, etag: "abc") { |range, io| io.write("x" * range.size) }
    assert_equal 206, status
  end
end
