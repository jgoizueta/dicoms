require 'fileutils'
require 'dicom'
require 'modalsettings'
require 'sys_cmd'
require 'narray'

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

  def dicom?(file)
    ok = false
    if File.file?(file)
      File.open(file, 'rb') do |data|
        data.seek 128, IO::SEEK_SET # skip preamble
        ok = (data.read(4) == 'DICM')
      end
    end
    ok
  end

  # Find DICOM files in a directory;
  # Return the file names in an array.
  # DICOM files with a numeric part in the name are returned first, ordered
  # by the numeric value.
  # DICOM files with non-numeric names are returned last ordered by name.
  def find_dicom_files(dicom_directory)
    files = Dir.glob(File.join(dicom_directory, '*')).select{|f| dicom?(f)}
    non_numeric = []
    numeric_files = []
    files.each do |name|
      match = /\d+/.match(name)
      if match
        numeric_files << [match[0], name]
      else
        non_numeric << name
      end
    end
    numeric_files.sort_by{ |text, name| text.to_i }.map(&:last) + non_numeric.sort
  end

  # remap the dicom values of a set of images to maximize dynamic range
  # and avoid negative values
  # options:
  # * :level - apply window leveling
  # * :drop_base_level - remove lowest level (only if not doing window leveling)
  def remap(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      puts "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    output_dir = options[:output] || (dicom_directory+'_remapped')
    FileUtils.mkdir_p output_dir

    if options[:level] || options[:keep]
      options = options.merge(drop_base_level: false)
    end

    if options[:first_range] || options[:level] || options[:keep]
      # will use the range of the first image for all of them
      range = nil
    else
      # will compute the actual range of all the images
      v0 = minimum = maximum = nil
      dicom_files.each do |file|
        d = DICOM::DObject.read(file)
        # TODO: level8 options that applies level and normalizes to 0-255
        # but avoids normalization (just offsets) if the range is already < 255
        if options[:level]
          # apply window leveling
          data = d.narray(level: true)
        else
          data = d.narray
        end
        d_v0, d_min, d_max = data_range(d, data, options)
        v0 ||= d_v0
        minimum ||= d_min
        maximum ||= d_max
        v0 = d_v0 if v0 > d_v0
        minimum = d_min if minimum > d_min
        maximum = d_max if maximum < d_max
      end
      range = [v0, minimum, maximum]
    end

    dicom_files.each do |file|
      d = DICOM::DObject.read(file)

      signed = d.send(:signed_pixels?)
      if d.bits_stored.value.to_i == 16
        default_max = signed ? 32767 : 65525
        offset = signed ? 32768 : 0
      else
        default_max = signed ? 127 : 255
        offset = signed ? 128 : 0
      end
      output_max = options[:max] || default_max
      output_min = options[:min] || 0

      if options[:level]
        # apply window leveling
        data = d.narray(level: true)
      else
        data = d.narray
      end

      if options[:keep]
        data += offset
        d.window_center = d.window_center.value.to_i + offset
      else
        range ||= data_range(d, data, options)
        data = optimize_dynamic_range(d, data, output_min, output_max, options.merge(range: range))

        d.window_center = (output_max + output_min) / 2
        d.window_width = (output_max - output_min)
      end
      d.pixels = data

      output_file = File.join(output_dir, File.basename(file))
      d.write output_file
    end
  end

  def pack(dicom_directory, options = {})
    # TODO: remap modes:
    # a) preserve -2048,2048 / parameterized min/max
    # b) preserve global max, min with drop_min option
    # c) preserve first image max, min with drop_min option [or use a sample]
    # keep remapping parameters in metadata

    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      puts "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    output_name = (options[:output] || File.basename(dicom_directory)) + '.mkv'
    pack_dir = options[:tmp] || 'dicompack_tmp' # TODO:...
    FileUtils.mkdir_p pack_dir

    name_pattern = start_number = prefix = nil
    metadata = Settings[]
    first_z = nil
    last_z = nil
    n = 0

    range = nil
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
      if range.nil?
        if options[:level]
          # apply window leveling
          data = d.narray(level: true)
        else
          data = d.narray
        end
        range = data_range(d, data, options.merge(first_range: true))
        options = options.merge(range: range)
      end
      output_image = output_file_name(pack_dir, prefix, file)
      save_jpg d, output_image, options
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

  def data_range(dicom, data, options = {})
    if options[:level]
      center = dicom.window_center.value.to_i
      width  = dicom.window_width.value.to_i
      low = center - width/2
      high = center + width/2
      return [low, low, high]
    end
    v0 = data.min
    maximum = data.max
    if options[:drop_base_level]
      minimum = maximum
      data.each { |v| minimum = [v, minimum].min if v > v0 }
    else
      minimum = v0
    end
    if options[:first_range]
      # extend the range slightly
      if options[:first_range].is_a?(Numeric)
        k = options[:first_range].to_f
      else
        k = 0.1
      end
      v0, minimum, maximum = extend_data_range(k, v0, minimum, maximum)
    end
    [v0, minimum, maximum]
  end

  def extend_data_range(k, v0, minimum, maximum)
    k += 1.0
    c = (maximum + minimum)/2
    if v0 == minimum
      v0 = minimum = (c + k*(minimum - c)).round
    else
      minimum = [v0+1, (c + k*(minimum - c)).round].max
    end
    maximum = (c + k*(maximum - c)).round
    [v0, minimum, maximum]
  end

  def optimize_dynamic_range(dicom, data, output_min, output_max, options = {})
    if options[:range]
      v0, minimum, maximum = options[:range]
    else
      v0, minimum, maximum = data_range(dicom, data, options)
    end
    r = (maximum - minimum).to_f

    data[data <= v0] = minimum if v0 < minimum
    data -= minimum
    data *= (output_max - output_min)/r
    data += output_min
    data
  end

  def save_jpg(dicom, output_image, options = {})
    image_options = { narray: true }
    if options[:level]
      image_options[:level] = true
    end
    if options[:optimize]
      if dicom.bits_stored.value.to_i == 16
        if dicom.send(:signed_pixels?)
          min, max = -32767, 32767
        else
          min, max = 0, 65535
        end
      else
        min, max = 0, 255
      end
      data = optimize_dynamic_range(dicom, dicom.narray(image_options), min, max, options)
      dicom.pixels = data
      image = dicom.image
    else
      image = dicom.image(image_options).normalize
    end
    if DICOM.image_processor == :mini_magick
      image.format('jpg')
    end
    image.write(output_image)
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
      # TODO: + min, max (original values corresponding to 0, 255)
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
