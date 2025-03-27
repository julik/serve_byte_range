lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "serve_byte_range/version"

Gem::Specification.new do |spec|
  spec.name = "serve_byte_range"
  spec.version = ServeByteRange::VERSION
  spec.authors = ["Julik Tarkhanov", "Sebastian van Hesteren"]
  spec.email = ["me@julik.nl"]
  spec.license = "MIT"
  spec.summary = "Serve byte range HTTP responses lazily"
  spec.description = "Serve byte range HTTP responses lazily"

  spec.homepage = "https://github.com/julik/serve_byte_range"
  # The homepage link on rubygems.org only appears if you add homepage_uri. Just spec.homepage is not enough.
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  # spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.files = `git ls-files -z`.split("\x0")
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "rack", ">= 1.0"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "standard", "1.28.5" # Needed for 2.6
  spec.add_development_dependency "yard", "~> 0.9"
  spec.add_development_dependency "sord"
  spec.add_development_dependency "redcarpet"
end
