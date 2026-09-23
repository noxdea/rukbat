# frozen_string_literal: true

require_relative "lib/rukbat/version"

Gem::Specification.new do |spec|
  spec.name = "rukbat"
  spec.version = Rukbat::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Spreadsheet application with sparse storage and incremental formulas"
  spec.description = "A Ruby spreadsheet app built on persistent sparse sheets and the Furud calculation engine."
  spec.homepage = "https://github.com/noxdea/rukbat"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib,exe,sig}/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |path| File.file?(path) }
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |path| File.basename(path) }
  spec.require_paths = ["lib"]

  spec.add_dependency "denebola", "~> 0.2.0"
  spec.add_dependency "csv", "~> 3.3"
  spec.add_dependency "furud", "~> 0.1.0"
  spec.add_dependency "gienah", "~> 0.1.0"
  spec.add_dependency "kochab", "~> 0.2.0"
  spec.add_dependency "menkar", "~> 0.1.0"
  spec.add_dependency "okab", "~> 0.1.0"
  spec.add_dependency "spica", "~> 0.1.0"
  spec.add_dependency "xamidimura", "~> 0.1.0"
  spec.add_dependency "zaniah", "~> 0.6.0"
end
