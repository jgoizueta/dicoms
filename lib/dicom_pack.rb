require 'fileutils'
require 'dicom'
require 'modalsettings'
require 'sys_cmd'

class DicomPack

  def initialize(options = {})
    @settings = Settings[options]

    if @settings.image_processor
      DICOM.image_processor = @settings.image_processor.to_sym
    end

    @ffmpeg_options = { 'ffmpeg' => @settings.ffmpeg }
    # TODO: use quality level settings
    # TODO: temporary strategy option (:current_dir, :system_tmp, ...)
  end

  attr_reader :settings

  def pack(dicom_directory, options = {})

    dicom_files = Dir.glob(File.join(dicom_directory, '*.dcm'))
    if dicom_files.empty?
      puts "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    # TODO: do we need to sort dicom_files?

    output_name = (options[:output] || File.basename(dicom_directory)) + '.mkv'
    pack_dir = options[:tmp] || 'dicompack_tmp' # TODO:...
    FileUtils.mkdir_p pack_dir

    name_pattern = start_number = prefix = nil
    metadata = Settings[]
    first_z = nil
    last_z = nil
    n = 0

    first = true
    dicom_files.each do |file|
      d = DICOM::DObject.read(file)
      n += 1
      md = single_dicom_metadata(d)
      metadata.merge!(
        nx: md.nx, ny: md.ny,
        dx: md.dx, dy: md.dy
      )
      last_z = md.slice_z
      unless first_z
        first_z = last_z
        prefix, name_pattern, start_number = dicom_name_pattern(file, pack_dir)
      end
      output_image = output_file_name(pack_dir, prefix, file)
      save_jpg d, output_image
    end
    metadata.nz = n
    metadata.dz = (last_z - first_z)/(n-1)
    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-start_number', start_number
      option '-i', name_pattern
      option '-vcodec', 'mjpeg'
      option '-q:v', '2.0'
      metadata.each do |key, value|
        option '-metadata', key, equal_value: value
      end
      file output_name
    end
    ffmpeg.run
    check_command ffmpeg
  end

  def unpack(pack_file, options = {})

    unpack_dir = options[:output] || File.basename(pack_file, '.mkv')
    FileUtils.mkdir_p unpack_dir

    prefix = File.basename(pack_file, '.mkv')
    output_file_pattern = File.join(unpack_dir, "#{prefix}-%3d.jpeg")

    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-i', file: pack_file
      option '-q:v', 2
      file output_file_pattern
    end
    ffmpeg.run
    check_command ffmpeg

    metadata_file = File.join(unpack_dir, 'metadata.txt')
    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-i', file: pack_file
      option '-f', 'ffmetadata'
      file metadata_file
    end
    ffmpeg.run
    check_command ffmpeg

    metadata = File.read(metadata_file).lines[1..-1].map { |line|
      key, value = line.strip.split('=')
      key = key.downcase.to_sym
      trans = METADATA_TYPES[key]
      value = value.send(trans) if trans
      [key, value]
    }
    metadata = Hash[*metadata.flatten]
    metadata_yaml = File.join(unpack_dir, 'metadata.yml')
    File.open(metadata_yaml, 'w') do |yaml|
      yaml.write metadata.to_yaml
    end
  end

  private

  def save_jpg(dicom, output_image)
    if DICOM.image_processor == :mini_magick
      dicom.image.normalize.format('jpg').write(output_image)
    else
      dicom.image.normalize.write(output_image)
    end
  end

  METADATA_TYPES = {
    dx: :to_f, dy: :to_f, dz: :to_f,
    nx: :to_i, ny: :to_i, nz: :to_i
  }

  def check_command(command)
    unless command.success?
      puts "Error executing:"
      puts "  #{command}"
      puts command.output
      exit 1
    end
  end

  def single_dicom_metadata(dicom)
    dx, dy = dicom.pixel_spacing.value.split('\\').map(&:to_f)
    x, y, z = dicom.image_position_patient.value.split('\\').map(&:to_f)
    if settings.use_slice_z
      # according to http://www.vtk.org/Wiki/VTK/FAQ#The_spacing_in_my_DICOM_files_are_wrong
      # this is not reliable
      slice_z = dicom.slice_location.value.to_f
    else
      slice_z = z
    end
    nx = dicom.num_cols # dicom.columns.value.to_i
    ny = dicom.num_rows # dicom.rows.value.to_i

    unless dicom.samples_per_pixel.value.to_i == 1
      raise "Invalid DICOM format"
    end
    Settings[
      dx: dx, dy: dy, x: x, y: y, z: z,
      slice_z: slice_z, nx: nx, ny: ny
    ]
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


end
