require 'rubygems'
require 'bundler/setup'

require 'fileutils'
require 'dicom'

require 'yaml'

pack_file = ARGV.shift
unless pack_file && File.file?(pack_file)
  puts "Uso:"
  puts "  unpack archivo-pack"
  if pack_file
    puts "ERROR: no se ha encontrado el archivo:\n  #{pack_file}"
  end
  exit 1
end

# TODO: let the user specify the temporary directory or choose a better location
unpack_dir = 'dicompack_out'
FileUtils.mkdir_p unpack_dir

prefix = File.basename(pack_file, '.mkv')
output_file_pattern = File.join(unpack_dir, "#{prefix}-%3d.jpeg")

ffmpeg_cmd = %{ffmpeg -i #{pack_file} -q:v 2 #{output_file_pattern}}
#system ffmpeg_cmd

metadata_file = File.join(unpack_dir, 'metadata.txt')
ffmpeg_cmd = %{ffmpeg -i #{pack_file} -f ffmetadata #{metadata_file}}
#system ffmpeg_cmd
TYPES = {
  dx: :to_f, dy: :to_f, dz: :to_f,
  nx: :to_i, ny: :to_i, nz: :to_i
}
metadata = File.read(metadata_file).lines[1..-1].map { |line|
  key, value = line.strip.split('=')
  key = key.downcase.to_sym
  trans = TYPES[key]
  value = value.send(trans) if trans
  [key, value]
}
metadata = Hash[*metadata.flatten]
metadata_yaml = File.join(unpack_dir, 'metadata.yml')
File.open(metadata_yaml, 'w') do |yaml|
  yaml.write metadata.to_yaml
end


# ffprobe -show_format #{pack_file}
