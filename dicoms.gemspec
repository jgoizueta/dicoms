# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'dicoms/version'

Gem::Specification.new do |spec|
  spec.name          = "dicoms"
  spec.version       = DicomS::VERSION
  spec.authors       = ["Javier Goizueta"]
  spec.email         = ["jgoizueta@gmail.com"]

  spec.summary       = %q{DICOM Series toolkit}
  spec.description   = %q{Toolkit for working with DICOM image sequences}
  spec.homepage      = "https://gitlab.com/jgoizueta/dicompacker"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'dicom'
  # spec.add_dependency 'dicom', 'mini_magick'
  spec.add_dependency 'rmagick', '~> 2.14'
  spec.add_dependency 'sys_cmd', '>= 0.2.1'
  spec.add_dependency 'modalsettings', '~> 1.0.1'
  spec.add_dependency 'narray', '~> 0.6'
  spec.add_dependency 'thor', '~> 0.19'
  spec.add_dependency 'solver', '>= 0.2.0'
  spec.add_dependency 'histogram', '~> 0.2.4'

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest"
end
