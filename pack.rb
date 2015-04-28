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
if ARGV.shift == 'level'
  packer.pack dicom_directory, level: true
else
  packer.pack dicom_directory, optimize: true, drop_base_level: true
end
# TODO option for custom window (center, width)
