# frozen_string_literal: true

source "https://rubygems.org"

gemspec
%w[alhena denebola furud gienah kochab menkar okab spica zaniah].each do |name|
  local_path = File.expand_path("../#{name}", __dir__)
  gem name, path: local_path if File.directory?(local_path)
end
gem "rake", "~> 13.0"
gem "rbs", "~> 3.6"
gem "rspec", "~> 3.0"
