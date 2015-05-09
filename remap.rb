require 'rubygems'
require 'bundler/setup'

require 'fileutils'
require 'dicom'

require_relative 'lib/dicom_pack'

dicom_directory = ARGV.shift
mode = ARGV.shift

# TODO: read settings
settings = {}
packer = DicomPack.new(settings)

# TODO: parameters to choose the strategy
if mode == 'window'
  puts "Window"
  packer.remap dicom_directory, strategy: :window
elsif mode == 'drop'
  puts "Drop"
  packer.remap dicom_directory, strategy: :sample, drop_base: true
elsif mode == 'unsigned'
  packer.remap dicom_directory, strategy: :unsigned
else
  puts "Sample"
  packer.remap dicom_directory, strategy: :sample
end
