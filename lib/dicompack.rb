require 'fileutils'
require 'dicom'
require 'modalsettings'
require 'sys_cmd'
require 'narray'

require "dicompack/version"
require "dicompack/meta_codec"
require "dicompack/strategy"

# TODO: require known SOP Class: 1.2.840.10008.5.1.4.1.1.2
# (in tag 0002,0002, Media Storage SOP Class UID)
# And Transfer Syntax 0002,0010 1.2.840.10008.1.2:
#   Implicit VR Little Endian: Default Transfer Syntax for DICOM
#

# TODO: option for pack to restore DICOM files;
# we need to adjust metadata elements (which refer to first slice)
# to each slice.
# elements that vary from slice to slice but whose variation probably doesn't matter:
#   0008,0033     Content Time
# elements that vary and should be removed:
#   0018,1151     X-Ray Tube Current
#   0018,1152     Exposure
# elements that should be adjusted:
#   0020,0013     Instance Number # increment by 1 for each slice
#   0020,0032     Image Position (Patient) # should be computed from additional metadata (dz)
#   0020,1041     Slice Location  # should be computed from additional metadata (dz)
# elements that may need adjusting depending on value restoration method:
#   0028,0100     Bits Allocated
#   0028,0101     Bits Stored
#   0028,0102     High Bit
#   0028,0103     Pixel Representation
#   0028,1050     Window Center
#   0028,1051     Window Width
#   0028,1052     Rescale Intercept
#   0028,1053     Rescale Slope
#   0028,1054     Rescale Type
# also, these element should be removed (because Pixel data is set by assigning an image)
#   7FE0,0000     Group Length
#   7FE0,0010     Pixel Data
# other varying elements that need further study: (vary in some studies)
#   0002,0000     File Meta Information Group Length # drop this and 0002,0001?
#   0002,0003     Media Storage SOP Instance UID
#   0008,0018     SOP Instance UID

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

  # Code that use images should be wrapped with this.
  #
  # Reason: if RMagick is used by DICOM to handle images
  # the first time it is needed, 'rmagick' will be required.
  # This has the effect of placing the path of ImageMagick
  # in front of the PATH.
  # On Windows, ImageMagick includes FFMPeg in its path and we
  # may require a later version than the bundled with IM,
  # so we keep the original path rbefore RMagick alters it.
  # We may be less dependant on the FFMpeg version is we avoid
  # using the start_number option by renumbering the extracted
  # images...
  def keeping_path
    path = ENV['PATH']
    yield
  ensure
    ENV['PATH'] = path
  end

  # Replace ALT_SEPARATOR in pathname (Windows)
  def normalized_path(path)
    if File::ALT_SEPARATOR
      path.gsub(File::ALT_SEPARATOR, File::SEPARATOR)
    else
      path
    end
  end

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
    dicom_directory = normalized_path(dicom_directory)
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

  # TODO: keep more metadata to restore the exact strategy+min,max and so
  # be able to restore original DICOM values (and rescaling/window metadata)
  # bit depth, signed/unsigned, rescale, window, data values corresponding
  # to minimum (black) and maximum (white)

  # extract the images of a set of DICOM files
  def extract(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    pack_dir = options[:output] || File.join(dicom_directory, 'images')

    name_pattern = start_number = prefix = nil
    metadata = Settings[]
    first_z = nil
    last_z = nil
    n = 0

    strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
    min, max = strategy.min_max(dicom_files)
    metadata.merge! min: min, max: max
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
      save_jpg d, output_image, strategy, min, max
    end
    metadata.nz = n
    metadata.dz = (last_z - first_z)/(n-1)
    # TODO: save metadata as yml/JSON in pack_dir
    pack_dir
  end

  # remap the dicom values of a set of images to maximize dynamic range
  # and avoid negative values
  # options:
  # * :level - apply window leveling
  # * :drop_base_level - remove lowest level (only if not doing window leveling)
  def remap(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    output_dir = options[:output] || (dicom_directory+'_remapped')
    FileUtils.mkdir_p output_dir


    if options[:strategy] != :unsigned
      strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
      min, max = strategy.min_max(dicom_files)
    end

    dd_hack = true
    # Hack to solve problem with some DICOMS having different header size
    # (incovenient for some tests) due to differing 0008,2111 element

    if dd_hack
      first = true
      dd = nil
    end

    dicom_files.each do |file|
      d = DICOM::DObject.read(file)
      if dd_hack
        dd = d.derivation_description if first
        d.derivation_description = dd
      end
      lim_min, lim_max = DynamicRangeStrategy.min_max_limits(d)
      if options[:strategy] == :unsigned
        if lim_min < 0
          offset = -lim_min
        else
          offset = 0
        end
      end
      if offset
        if offset != 0
          d.window_center = d.window_center.value.to_i + offset
          d.pixel_representation = 0
          data = d.narray
          data += offset
          d.pixels = data
        end
      else
        if (min < lim_min || max > lim_max)
          if min >= 0
            d.pixel_representation = 0
          else
            d.pixel_representation = 1
          end
        end
        lim_min, lim_max = DynamicRangeStrategy.min_max_limits(d)
        d.window_center = (lim_max + lim_min) / 2
        d.window_width = (lim_max - lim_min)
        d.pixels = strategy.processed_data(d, min, max)
      end
      output_file = File.join(output_dir, File.basename(file))
      d.write output_file
    end
  end

  def pack(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    output_name = (options[:output] || File.basename(dicom_directory)) + '.mkv'
    pack_dir = options[:tmp] || 'dicompack_tmp' # TODO:...
    FileUtils.mkdir_p pack_dir

    name_pattern = start_number = prefix = nil
    metadata = Settings[]
    first_z = nil
    last_z = nil
    n = 0

    strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
    min, max = strategy.min_max(dicom_files)
    metadata.merge! min: min, max: max
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
      save_jpg d, output_image, strategy, min, max
    end
    metadata.nz = n
    metadata.dz = (last_z - first_z)/(n-1)
    if options[:dicom_metadata]
      metadata_file = File.join(pack_fir, 'ffmetadata')
      # TODO: filter-out elements to be ignored
      meta_codec.write_metadata(DICOM::DObject.read(dicom_files.first), metadata_file, metadata.to_h)
    end
    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-start_number', start_number
      option '-i', name_pattern
      option '-vcodec', 'mjpeg'
      option '-q:v', '2.0'
      if metadata_file
        option '-i', metadata_file
        option '-map_metadata', 1
      else
        metadata.each do |key, value|
          option '-metadata', "dicom_#{key}", equal_value: value
        end
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

    dicom_elements, metadata = meta_codec.read_metadata(metadata_file)
    metadata = Hash[metadata.to_a.map { |key, value|
      key = key.to_s.downcase.to_sym
      trans = METADATA_TYPES[key]
      value = value.send(trans) if trans
      [key, value]
    }]
    # TODO:
    # now if dicom_elements are present and are going to be used,
    # we need to adjust slice-varying elements and associate to
    # each slice

    metadata_yaml = File.join(unpack_dir, 'metadata.yml')
    File.open(metadata_yaml, 'w') do |yaml|
      yaml.write metadata.to_yaml
    end
  end

  private

  def meta_codec
    MetaCodec.new
  end

  # def optimize_dynamic_range(data, output_min, output_max, options = {})
  #   minimum, maximum = options[:range]
  #   r = (maximum - minimum).to_f
  #   data -= minimum
  #   data *= (output_max - output_min)/r
  #   data += output_min
  #   data[data < output_min] = output_min
  #   data[data > output_max] = output_max
  #   data
  # end

  def save_jpg(dicom, output_image, strategy, min, max)
    keeping_path do
      image = strategy.image(dicom, min, max)
      if DICOM.image_processor == :mini_magick
        image.format('jpg')
      end
      image.write(output_image)
    end
  end

  METADATA_TYPES = {
    dx: :to_f, dy: :to_f, dz: :to_f,
    nx: :to_i, ny: :to_i, nz: :to_i,
    max: :to_i, min: :to_i
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
