# serve_byte_range

is a small utility for serving HTTP `Range` responses (partial content responses) from your Rails or Rack app. It will allow you to output partial content in a lazy manner without buffering, and perform correct encoding of `multipart/byte-range` responses. It will also make serving byte ranges safer because it coalesces the requested byte ranges into larger, consecutive ranges - reducing overhead.

## Installation and usage

Add it to your Gemfile:

```shell
bundle add serve_byte_range
```

and use code like this to serve a large `File` object:

```ruby
status, headers, body = serve_ranges(env, resource_size: File.size(path_to_large_file)) do |range_in_file, io|
  File.open(path_to_large_file, "rb") do |file|
    file.seek(range_in_file.begin)
    # `io` is an object that responds to `#write` and yields bytes to the Rack-compatible webserver
    IO.copy_stream(file, io, range_in_file.size)
  end
end
[status, headers, body] # And return the Rack response "triplet"
```

You can also retrieve the `range_in_file` from an external resource, you can also do it in chunks - whatever you prefer. The important thing is that your response - even for multiple ranges:

* Will be correctly pre-sized with `Content-Length`
* Will not be generated and buffered eagerly, but will get generated as you serve the content out

Strings you `write` which are already in the `BINARY` encoding get passed on to the webserver without copying. `IO.copy_stream` and `IO#readpartial` with a buffer reuse the same `String` for every chunk, so if anything between you and the socket retains the chunks instead of writing them out immediately (a buffering middleware, for example), it will end up with clobbered data. In that case, `dup` the strings yourself before writing them.


## Serving a resource made of several segments

If your response is glued together from several pieces - byte ranges of objects in S3, literal strings and so on - use a `ServeByteRange::Sequence`. A segment can be any object, since you give its size explicitly. For every requested range you get the segments it touches, along with the range of bytes inside each segment:

```ruby
header_file = File.open("header.bin", "rb")

seq = ServeByteRange::Sequence.new
seq.add_segment(header_file, size: header_file.size, etag: "#{header_file.mtime.to_i}-#{header_file.size}")
seq.add_segment(s3_object, size: s3_object.content_length, etag: s3_object.etag)
seq << "--- redacted ---\n" # Strings are sized in bytes, and their contents go into the ETag
seq.add_segment(other_s3_object, size: other_s3_object.content_length, etag: other_s3_object.etag)

status, headers, body = ServeByteRange.serve_sequence(env, seq) do |segment, range_in_segment, io|
  case segment
  when String
    io.write(segment.byteslice(range_in_segment))
  when File
    # Copies range_in_segment.size bytes starting at range_in_segment.begin, without moving the file position
    IO.copy_stream(segment, io, range_in_segment.size, range_in_segment.begin)
  when Aws::S3::Object
    # Passing a block to `get` streams the body in chunks instead of buffering it in memory
    segment.get(range: "bytes=%d-%d" % [range_in_segment.begin, range_in_segment.end]) do |chunk|
      io.write(chunk)
    end
  end
end

# The webserver calls `close` on the body once the response is sent, or if the client goes away
[status, headers, Rack::BodyProxy.new(body) { header_file.close }]
```

The body is generated lazily while the webserver sends the response, so the `File` has to stay open until then. Closing it right after `serve_sequence` returns would break the response, and not closing it at all leaks a file descriptor per request - hence the `Rack::BodyProxy`.

The `ETag` of the response is derived from the ETags of the segments. If you do not give an `etag:` for a segment, its size is used instead, and a change which keeps the size the same will not change the `ETag` of the `Sequence`. Sequences can be nested. If a segment writes more or fewer bytes than its range requires, you get an exception saying which segment it was.

## Development

Range parsing is delegated to Rack, and its behavior differs between Rack versions. To run the tests against a specific major version of Rack:

```shell
BUNDLE_GEMFILE=gemfiles/rack_2.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rack_2.gemfile bundle exec rake test
```

CI runs the tests against both `gemfiles/rack_2.gemfile` and `gemfiles/rack_3.gemfile`.
