# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"
require "rdoc/task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task :format do
  `bundle exec standardrb --fix`
  `bundle exec magic_frozen_string_literal .`
end

RDoc::Task.new(:rdoc) do |rd|
  rd.rdoc_dir = "doc"
  rd.main = "README.md"
  rd.markup = "markdown"
  rd.rdoc_files.include("README.md", "lib/**/*.rb")
end

# rbs-inline and steep need Ruby 3.1+, so they live in a Gemfile of their own
TYPECHECK_ENV = {"BUNDLE_GEMFILE" => File.expand_path("gemfiles/typecheck.gemfile", __dir__)}

desc "Generate RBS signatures in sig/ from the inline annotations in lib/"
task :rbs do
  sh TYPECHECK_ENV, "bundle exec rbs-inline --output=sig lib"
end

desc "Typecheck with Steep"
task steep: :rbs do
  sh TYPECHECK_ENV, "bundle exec steep check"
end

task default: [:test, :standard]
