# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'dicompack/version'

Gem::Specification.new do |spec|
  spec.name          = "dicompack"
  spec.version       = DicomPack::VERSION
  spec.authors       = ["Javier Goizueta"]
  spec.email         = ["jgoizueta@gmail.com"]

  spec.summary       = %q{DICOM sequence packer}
  spec.description   = %q{Pack DICOM image sequences into a compact file}
  spec.homepage      = "https://gitlab.com/jgoizueta/dicompacker"

  # Prevent pushing this gem to RubyGems.org by setting 'allowed_push_host', or
  # delete this section to allow pushing this gem to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "http://jgoizueta.net"
  else
    raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'dicom'
  # spec.add_dependency 'dicom', 'mini_magick'
  add_dependency 'rmagick', '~> 2.14'
  add_dependency 'sys_cmd', '>= 0.2.1'
  add_dependency 'modalsettings', '~> 1.0.1'
  add_dependency 'narray', '~> 0.6'
  add_dependency 'thor', '~> 0.19'


  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest"
end
