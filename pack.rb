require 'rubygems'
require 'bundler/setup'

require 'fileutils'
require 'dicom'

require_relative 'lib/dicom_pack'

dicom_directory = ARGV.shift
unless dicom_directory && File.directory?(dicom_directory)
  puts "Uso:"
  puts "  pack directorio-imagen-dicom"
  if dicom_directory
    puts "ERROR: no se ha encontrado el directorio:\n  #{dicom_directory}"
  end
  exit 1
end

# TODO: read settings
settings = {}
packer = DicomPack.new(settings)

# TODO: parameters to choose the strategy
mode = ARGV.shift
if mode == 'window'
  puts "Window"
  packer.pack dicom_directory, stategy: :window
elsif mode == 'drop'
  puts "Drop"
  packer.pack dicom_directory, strategy: :sample, drop_base: true
else
  puts "Sample"
  packer.pack dicom_directory, strategy: :sample
end
