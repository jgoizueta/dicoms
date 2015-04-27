require 'rubygems'
require 'bundler/setup'

require 'fileutils'
require 'dicom'

require 'yaml'

require_relative 'lib/dicom_pack'

pack_file = ARGV.shift
unless pack_file && File.file?(pack_file)
  puts "Uso:"
  puts "  unpack archivo-pack"
  if pack_file
    puts "ERROR: no se ha encontrado el archivo:\n  #{pack_file}"
  end
  exit 1
end

# TODO: read settings
settings = {}
packer = DicomPack.new(settings)
packer.unpack pack_file
