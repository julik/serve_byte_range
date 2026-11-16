# frozen_string_literal: true

require "bundler"
Bundler.setup

require_relative "../lib/serve_byte_range"
require "minitest"
require "minitest/autorun"
require "stringio"

class SequenceTest < Minitest::Test
  # Stands in for an object in remote storage which supports ranged GETs
  RemoteObject = Struct.new(:bytes) do
    def size
      bytes.bytesize
    end

    def get_range(range)
      bytes.byteslice(range)
    end
  end

  def fetch(segment, range_in_segment)
    (segment.is_a?(String) ? segment.byteslice(range_in_segment) : segment.get_range(range_in_segment)).b
  end

  def build_sequence_and_expected_bytes
    rng = Random.new(Minitest.seed)
    remote = RemoteObject.new(rng.bytes(200))
    inner = ServeByteRange::Sequence.new("«inner — ✂»").add_segment(RemoteObject.new(rng.bytes(7)), size: 7, etag: "inner-v1")

    seq = ServeByteRange::Sequence.new
    seq.add_segment(remote, size: remote.size, etag: "v1")
    seq << "«redacted — ✂»\n"
    seq << ""
    seq << inner
    seq.add_segment(RemoteObject.new(rng.bytes(3)), size: 3, etag: "tail-v1")

    expected = remote.bytes + "«redacted — ✂»\n".b + inner.each_in_range(0..(inner.size - 1)).map { |s, r| fetch(s, r) }.join.b
    seq.each_in_range((seq.size - 3)..(seq.size - 1)) { |s, r| expected << fetch(s, r) }
    [seq, expected]
  end

  def test_size_and_each_in_range_cover_every_byte
    seq, expected = build_sequence_and_expected_bytes
    assert_equal expected.bytesize, seq.size

    rng = Random.new(Minitest.seed)
    ranges = [0..0, 0..(seq.size - 1), 195..215, 199..200, (seq.size - 1)..(seq.size - 1)]
    50.times do
      a, b = [rng.rand(seq.size), rng.rand(seq.size)].sort
      ranges << (a..b)
    end

    ranges.each do |range|
      out = +"".b
      seq.each_in_range(range) { |segment, range_in_segment| out << fetch(segment, range_in_segment) }
      assert_equal expected.byteslice(range), out, "Mismatch for #{range}"
    end
  end

  def test_each_in_range_yields_leaf_segments_with_ranges_inside_them
    seq = ServeByteRange::Sequence.new("abc", ServeByteRange::Sequence.new("de", "fgh"), "ij")
    assert_equal [["abc", 2..2], ["de", 0..1], ["fgh", 0..0]], seq.each_in_range(2..5).to_a
    assert_equal [["fgh", 2..2], ["ij", 0..1]], seq.each_in_range(7..9).to_a
    assert_equal [], seq.each_in_range(10..12).to_a
    assert_equal [], ServeByteRange::Sequence.new.each_in_range(0..1).to_a
  end

  def test_add_segment_skips_empty_segments_and_refuses_bad_sizes
    seq = ServeByteRange::Sequence.new
    seq.add_segment(:nothing, size: 0)
    assert_equal 0, seq.size
    assert_raises(ArgumentError) { seq.add_segment(:x, size: -1) }
    assert_raises(ArgumentError) { seq.add_segment(:x, size: "1") }
  end

  def test_etag_changes_when_a_segment_does
    a = ServeByteRange::Sequence.new("abc", "def")
    b = ServeByteRange::Sequence.new("abc", "deF")
    assert_match(/\A"[0-9a-f]{40}"\z/, a.etag)
    assert_equal a.etag, ServeByteRange::Sequence.new("abc", "def").etag
    refute_equal a.etag, b.etag
    refute_equal ServeByteRange::Sequence.new("ab", "c").etag, ServeByteRange::Sequence.new("a", "bc").etag

    nested_a = ServeByteRange::Sequence.new("x", a)
    nested_b = ServeByteRange::Sequence.new("x", b)
    refute_equal nested_a.etag, nested_b.etag
  end

  def test_serve_sequence_serves_whole_body_single_and_multiple_ranges
    seq, expected = build_sequence_and_expected_bytes
    serve = ->(env) { ServeByteRange.serve_sequence(env, seq, multipart_boundary: "azuleju") { |segment, r, io| io.write(fetch(segment, r)) } }
    read = ->(body) { StringIO.new.binmode.tap { |out| body.each { |chunk| out.write(chunk) } }.string }

    status, headers, body = serve.call({})
    assert_equal 200, status
    assert_equal seq.etag, headers["ETag"]
    assert_equal expected.bytesize.to_s, headers["Content-Length"]
    assert_equal expected, read.call(body)

    status, headers, body = serve.call("HTTP_RANGE" => "bytes=195-215")
    assert_equal 206, status
    assert_equal "bytes 195-215/#{seq.size}", headers["Content-Range"]
    assert_equal expected.byteslice(195..215), read.call(body)

    status, headers, body = serve.call("HTTP_RANGE" => "bytes=0-3,201-204", "HTTP_IF_RANGE" => seq.etag)
    assert_equal 206, status
    output = read.call(body)
    assert_equal headers["Content-Length"].to_i, output.bytesize
    assert_includes output, expected.byteslice(0..3)
    assert_includes output, expected.byteslice(201..204)

    status, _, _ = serve.call("HTTP_IF_NONE_MATCH" => seq.etag)
    assert_equal 304, status
  end

  def test_serve_sequence_complains_about_the_segment_which_wrote_the_wrong_amount
    seq = ServeByteRange::Sequence.new("abc", "def")
    _, _, body = ServeByteRange.serve_sequence({}, seq) { |segment, r, io| io.write(segment[r]) unless segment == "def" }
    error = assert_raises(RuntimeError) { body.each {} }
    assert_includes error.message, "segment (String, bytes 0-2 of it) requires 3 bytes"

    _, _, body = ServeByteRange.serve_sequence({}, seq) { |segment, r, io| io.write(segment + "!") }
    error = assert_raises(RuntimeError) { body.each {} }
    assert_includes error.message, "the limit for this segment (String, bytes 0-2 of it) is 3"
  end

  def test_etag_is_weak_unless_every_segment_has_an_etag
    assert ServeByteRange::Sequence.new("abc").strong_etag?
    assert_match(/\A"[0-9a-f]{40}"\z/, ServeByteRange::Sequence.new("abc").etag)

    seq = ServeByteRange::Sequence.new("abc").add_segment(:remote, size: 10, etag: "v1")
    assert seq.strong_etag?

    seq.add_segment(:other_remote, size: 10)
    refute seq.strong_etag?
    assert_match(/\AW\/"[0-9a-f]{40}"\z/, seq.etag)

    refute ServeByteRange::Sequence.new("x", seq).strong_etag? # weakness carries over from nested sequences
  end

  def test_serves_range_regardless_of_if_range_when_etag_is_weak
    seq = ServeByteRange::Sequence.new.add_segment("abcdef", size: 6)
    env = {"HTTP_RANGE" => "bytes=0-1", "HTTP_IF_RANGE" => seq.etag}
    status, headers, _ = ServeByteRange.serve_sequence(env, seq) { |segment, r, io| io.write(segment[r]) }
    assert_equal 200, status # a weak validator can not be used for If-Range
    assert_equal seq.etag, headers["ETag"]

    status, _, _ = ServeByteRange.serve_sequence({"HTTP_IF_NONE_MATCH" => seq.etag}, seq) { |segment, r, io| io.write(segment[r]) }
    assert_equal 304, status
  end

  def test_etag_includes_segment_sizes
    a = ServeByteRange::Sequence.new.add_segment(:obj, size: 10, etag: "v1")
    b = ServeByteRange::Sequence.new.add_segment(:obj, size: 20, etag: "v1")
    refute_equal a.etag, b.etag
  end

  def test_etag_changes_when_segments_are_added_after_it_was_computed
    seq = ServeByteRange::Sequence.new("abc")
    etag_before = seq.etag
    seq << "def"
    refute_equal etag_before, seq.etag
    assert_same seq.etag, seq.etag
  end
end
