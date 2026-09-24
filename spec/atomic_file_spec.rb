# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rukbat::AtomicFile do
  it "does not replace a destination during a create-only install" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "temporary")
      target = File.join(directory, "target")
      File.write(source, "new")
      File.write(target, "existing")

      expect { described_class.install(source, target, replace: false) }.to raise_error(SystemCallError)
      expect(File.read(target)).to eq("existing")
    end
  end
end
