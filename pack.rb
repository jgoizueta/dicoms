require 'rubygems'
require 'bundler/setup'

require 'fileutils'
require 'dicom'

# DICOM.image_processor = :mini_magick # with mini_magick PNGs are produced (?)

def single_dicom_metadata(d)
  dx, dy = d.pixel_spacing.value.split('\\').map(&:to_f)
  x, y, z = d.image_position_patient.value.split('\\').map(&:to_f)
  slice_z = d.slice_location.value.to_f
  # TODO: use z for slice_z, because of: http://www.vtk.org/Wiki/VTK/FAQ#The_spacing_in_my_DICOM_files_are_wrong
  nx = d.num_cols # d.columns.value.to_i
  ny = d.num_rows # d.rows.value.to_i

  unless d.samples_per_pixel.value.to_i == 1
    raise "Invalid DICOM format"
  end
  {
    dx: dx, dy: dy, x: x, y: y, z: z,
    slice_z: slice_z, nx: nx, ny: ny
  }
end

def output_file_name(dir, prefix, name)
  File.join dir, "#{prefix}#{File.basename(name,'.dcm')}.jpg"
end

def dicom_name_pattern(name, output_dir)
  dir = File.dirname(name)
  file = File.basename(name)
  number_pattern = /\d+/
  match = number_pattern.match(file)
  raise "Invalid DICOM file name" unless match
  number = match[0]
  file = file.sub(number_pattern, "%d")
  if match.begin(0) == 0
    # ffmpeg has troubles with filename patterns starting with digits, so we'll add a prefix
    prefix = "d-"
  else
    prefix = nil
  end
  pattern = output_file_name(output_dir, prefix, file)
  [prefix, pattern, number]
end

dicom_directory = ARGV.shift
unless dicom_directory && File.directory?(dicom_directory)
  puts "Uso:"
  puts "  pack directorio-imagen-dicom"
  if dicom_directory
    puts "ERROR: no se ha encontrado el directorio:\n  #{dicom_directory}"
  end
  exit 1
end

dicom_files = Dir.glob(File.join(dicom_directory, '*.dcm'))
if dicom_files.empty?
  puts "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
end

# TODO: do we need to sort dicom_files?

# TODO: let the user specify the temporary directory or choose a better location
pack_dir = 'dicompack_tmp'
FileUtils.mkdir_p pack_dir

name_pattern = start_number = prefix = nil
metadata = {}
first_z = nil
last_z = nil
n = 0

first = true
dicom_files.each do |file|
  d = DICOM::DObject.read(file)
  n += 1
  md = single_dicom_metadata(d)
  metadata.merge!(
    nx: md[:nx], ny: md[:ny],
    dx: md[:dx], dy: md[:dy]
  )
  last_z = md[:slice_z]
  unless first_z
    first_z = last_z
    prefix, name_pattern, start_number = dicom_name_pattern(file, pack_dir)
  end
  output_image = output_file_name(pack_dir, prefix, file)
  if true # DEBUG
  d.image.normalize.write(output_image)
  end
end
metadata[:nz] = n
metadata[:dz] = (last_z - first_z)/(n-1)
ffmpeg_cmd = "ffmpeg -start_number #{start_number} -i #{name_pattern} -vcodec mjpeg -q:v 2.0"
metadata.each do |key, value|
  ffmpeg_cmd << %{ -metadata #{key}="#{value}"}
end
ffmpeg_cmd << " output.mkv"
puts "Execute:\n#{ffmpeg_cmd}\n\n"
system ffmpeg_cmd
# problem: ffmpeg doesn't like the JPEGs produced by Imagemagick:
#   [IMGUTILS @ 0x7fff5ed368f0] Picture size 20444x32251 is invalid
#   [mjpeg @ 0x7fec3280fc00] mjpeg: unsupported coding type (c5)
#   [mjpeg @ 0x7fec3280fc00] huffman table decode error
#   [mjpeg @ 0x7fec3280fc00] mjpeg: unsupported coding type (c6)
#   ...
