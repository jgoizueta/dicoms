require 'fileutils'
require 'dicom'
require 'modalsettings'
require 'sys_cmd'
require 'narray'
require_relative 'meta_codec'

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

  # TODO: keep more metadata to restore the exact strategy+min,max and so
  # be able to restore original DICOM values (and rescaling/window metadata)
  # bit depth, signed/unsigned, rescale, window, data values corresponding
  # to minimum (black) and maximum (white)

  # A Dynamic-range strategy determines how are data values
  # mapped to pixel intensities in images
  class DynamicRangeStrategy
    # TODO: rename this class to RangeMapper or DataMapper ...

    def initialize(options = {})
    end

    def image(dicom, min, max)
      dicom.pixels = processed_data(dicom, min, max)
      dicom.image
    end

    def self.min_max_strategy(strategy, options = {})
      case strategy
      when :fixed
        strategy_class = FixedStrategy
      when :window
        strategy_class = WindowStrategy
      when :first
        strategy_class = FirstStrategy
      when :global
        strategy_class = GlobalStrategy
      when :sample
        strategy_class = SampleStrategy
      end
      strategy_class.new options
    end

    def self.min_max_limits(dicom)
      signed = dicom.send(:signed_pixels?)
      if dicom.bits_stored.value.to_i == 16
        if signed
          [-32768, 32767]
        else
          [0, 65535]
        end
      elsif signed
        [-128, 127]
      else
        [0, 255]
      end
    end

  end

  # Apply window-clipping; also
  # always apply rescale (remap)
  class WindowStrategy < DynamicRangeStrategy

    def initialize(options = {})
      @center = options[:center]
      @width  = options[:width]
    end

    def min_max(files)
      # TODO: use options to sample/take first/take all?
      dicom = DICOM::DObject.read(files.first)
      data_range dicom
    end

    def processed_data(dicom, min, max)
      center = (min + max)/2
      width = max - min
      data = dicom.narray(level: [center, width])
      output_min, output_max = DynamicRangeStrategy.min_max_limits(dicom)
      data -= min
      data *= (output_max - output_min).to_f/(max - min)
      data += output_min
      data
    end

    # def image(dicom, min, max)
    #   center = (min + max)/2
    #   width = max - min
    #   dicom.image(level: [center, width]).normalize
    # end

    private

    USE_DATA = false

    def data_range(dicom)
      if USE_DATA
        if @center && @width
          level = [@center, @width]
        else
          level = true
        end
        data = dicom.narray(level: level)
        [data.min, data.max]
      else
        center = @center || dicom.window_center.value.to_i
        width  = @width  || dicom.window_width.value.to_i
        low = center - width/2
        high = center + width/2
        [low, high]
      end
    end

  end

  # These strategies
  # have optional dropping of the lowest level (base),
  # photometric rescaling, extension factor
  # and map the minimum/maximum input values
  # (determined by the particular strategy and files)
  # to the minimum/maximum output levels (black/white)
  class RangeStrategy < DynamicRangeStrategy

    def initialize(options = {})
      @rescale = options[:rescale]
      @drop_base = options[:drop_base]
      @extension_factor = options[:extend] || 0.0
      super options
    end

    def min_max(files)
      files = select_files(files)
      v0 = minimum = maximum = nil
      files.each do |file|
        d = DICOM::DObject.read(file)
        d_v0, d_min, d_max = data_range(d)
        v0 ||= d_v0
        minimum ||= d_min
        maximum ||= d_max
        v0 = d_v0 if v0 && d_v0 && v0 > d_v0
        minimum = d_min if minimum > d_min
        maximum = d_max if maximum < d_max
      end
      [minimum, maximum]
    end

    def processed_data(dicom, min, max)
      # Note: if DICOM would provide a way to control the +min_allowed+, +max_allowed+ parameters it
      # uses internally we could do this:
      #   if @rescale # TODO: || intercept == 0 && slope == 1
      #     center = (min + max)/2
      #     width = max - min
      #     dicom.narray(level: [center, width], min_allowed: min, max_allowd: max)
      #   ...
      output_min, output_max = DynamicRangeStrategy.min_max_limits(dicom)
      data = dicom.narray(level: false, remap: @rescale)
      r = (max - min).to_f
      data -= min
      data *= (output_max - output_min)/r
      data += output_min
      data[data < output_min] = output_min
      data[data > output_max] = output_max
      data
    end

    private

    def data_range(dicom)
      data = dicom.narray(level: false, remap: @rescale)
      base = nil
      minimum = data.min
      maximum = data.max
      if @drop_base
        base = minimum
        minumum  = data[data > base].min
      end
      if @extension_factor != 0
        # extend the range
        minimum, maximum = extend_data_range(@extension_factor, base, minimum, maximum)
      end
      [base, minimum, maximum]
    end

    def extend_data_range(k, base, minimum, maximum)
      k += 1.0
      c = (maximum + minimum)/2
      minimum = (c + k*(minimum - c)).round
      maximum = (c + k*(maximum - c)).round
      if base
        minimum = base + 1 if minimum <= base
      end
      [minimum, maximum]
    end

  end


  class FixedStrategy < RangeStrategy

    def initialize(options = {})
      @fixed_min = options[:min] || -2048
      @fixed_max = options[:max] || +2048
      options[:drop_base] = false
      options[:extend] = nil
      super options
    end

    def min_max(files)
      # TODO: set default min, max regarding dicom data type
      [@fixed_min, @fixed_max]
    end

  end

  class GlobalStrategy < RangeStrategy

    private

    def select_files(files)
      files
    end

  end

  class FirstStrategy < RangeStrategy

    def initialize(options = {})
      extend = options[:extend] || 0.3
      super options.merge(extend: extend)
    end

    private

    def select_files(files)
      [files.first].compact
    end

  end

  class SampleStrategy < RangeStrategy

    def initialize(options = {})
      @max_files = options[:max_files] || 8
      super options
    end

    private

    def select_files(files)
      n = [files.size, @max_files].min
      files.sample(n)
    end

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
    image = strategy.image(dicom, min, max)
    if DICOM.image_processor == :mini_magick
      image.format('jpg')
    end
    image.write(output_image)
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
