require 'rubygems'
require 'bundler/setup'

require 'fileutils'
require 'dicom'

require_relative 'lib/dicom_pack'

dicom_directory = ARGV.shift
level = ARGV.shift
do_level = (level == 'level')
do_keep = (level == 'keep')
unless dicom_directory && File.directory?(dicom_directory) && (!level || do_level || do_keep)
  puts "Uso:"
  puts "  remap directorio-imagen-dicom [level]"
  if dicom_directory
    puts "ERROR: no se ha encontrado el directorio:\n  #{dicom_directory}"
  end
  exit 1
end

# TODO: read settings
settings = {}
packer = DicomPack.new(settings)
packer.remap dicom_directory, drop_base_level: true, level: do_level, keep: do_keep
