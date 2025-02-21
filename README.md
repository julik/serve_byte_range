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

