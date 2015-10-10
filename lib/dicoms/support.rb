require 'matrix'

class DicomS
  class Error < RuntimeError
    def initialize(code, *args)
      @code = code
      super *args
    end
    attr_reader :code
  end

  class UnsupportedDICOM < Error
    def initialize(*args)
      super 'unsupported_dicom', *args
    end
  end

  class InvaliddDICOM < Error
    def initialize(*args)
      super 'invalid_dicom', *args
    end
  end

  USE_SLICE_Z = false
  METADATA_TYPES = {
    # Note: for axisx, axisy, axisz decode_vector should be used
    dx: :to_f, dy: :to_f, dz: :to_f,
    nx: :to_i, ny: :to_i, nz: :to_i,
    max: :to_i, min: :to_i,
    lim_min: :to_i, lim_max: :to_i,
    rescaled: :to_i, # 0-false 1-true
    slope: :to_f, intercept: :to_f,
    bits: :to_i,
    signed: :to_i, # 0-false 1-true
    firstx: :to_i, firsty: :to_i, firstz: :to_i,
    lastx: :to_i, lasty: :to_i, lastz: :to_i,
    study_id: :to_s, series_id: :to_i,
    x: :to_f, y: :to_f, z: :to_f,
    slize_z: :to_f,
    reverse_x: :to_i, # 0-false 1-true
    reverse_y: :to_i, # 0-false 1-true
    reverse_z: :to_i, # 0-false 1-true
    axial_sx: :to_f,
    axial_sy: :to_f,
    coronal_sx: :to_f,
    coronal_sy: :to_f,
    sagittal_sx: :to_f,
    sagittal_sy: :to_f
  }

  module Support
    def cast_metadata(metadata)
      metadata = Hash[metadata.to_h.to_a.map { |key, value|
        key = key.to_s.downcase.to_sym
        trans = METADATA_TYPES[key]
        value = value.send(trans) if trans
        [key, value]
      }]
      Settings[metadata]
    end

    # Code that use images should be wrapped with this.
    #
    # Reason: if RMagick is used by DICOM to handle images,
    # then the first time it is needed, 'rmagick' will be required.
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
      # TODO: look recursively inside nested directories
      if File.directory?(dicom_directory)
        dicom_directory = normalized_path(dicom_directory)
        files = Dir.glob(File.join(dicom_directory, '*')).select{|f| dicom?(f)}
      elsif File.file?(dicom_directory) && dicom?(dicom_directory)
        files = [dicom_directory]
      else
        files = []
      end
      non_numeric = []
      numeric_files = []
      files.each do |name|
        base = File.basename(name)
        match = /\d+/.match(base)
        if match
          number = match[0]
          if base =~ /\AI\d\d\d\d\d\d\d\Z/
            # funny scheme found in some DICOMS:
            # the I is followed by the instance number (unpadded), then right
            # padded with zeros, then increased (which affects the last digit)
            # while it coincides with some prior value.
            match = /I(\d\d\d\d)/.match(base)
            number = match[1]
            number = number[0...-1] while number.size > 1 && number[-1] == '0'
            number_zeros = name[-1].to_i
            number << '0'*number_zeros
          end
          numeric_files << [number, name]
        else
          non_numeric << name
        end
      end
      numeric_files.sort_by{ |text, name| text.to_i }.map(&:last) + non_numeric.sort
    end

    def single_dicom_metadata(dicom)
      # 0028,0030 Pixel Spacing:
      dx, dy = dicom.pixel_spacing.value.split('\\').map(&:to_f)
      # 0020,0032 Image Position (Patient):
      x, y, z = dicom.image_position_patient.value.split('\\').map(&:to_f)
      # 0020,0037 Image Orientation (Patient):
      xx, xy, xz, yx, yy, yz = dicom.image_orientation_patient.value.split('\\').map(&:to_f)
      if USE_SLICE_Z
        # according to http://www.vtk.org/Wiki/VTK/FAQ#The_spacing_in_my_DICOM_files_are_wrong
        # this is not reliable
        # 0020,1041 Slice Location:
        slice_z = dicom.slice_location.value.to_f
      else
        slice_z = z
      end

      # 0028,0011 Columns :
      nx = dicom.num_cols # dicom.columns.value.to_i
      # 0028,0010 Rows:
      ny = dicom.num_rows # dicom.rows.value.to_i

      unless dicom.samples_per_pixel.value.to_i == 1
        raise InvalidDICOM, "Invalid image format"
      end
      Settings[
        dx: dx, dy: dy, x: x, y: y, z: z,
        slice_z: slice_z, nx: nx, ny: ny,
        xaxis: encode_vector([xx,xy,xz]),
        yaxis: encode_vector([yx,yy,yz])
        # TODO: + min, max (original values corresponding to 0, 255)
      ]
    end

    def encode_vector(v)
      v.to_a*','
    end

    def decode_vector(v)
      Vector[*v.split(',').map(&:to_f)]
    end

    def output_file_name(dir, prefix, name, ext = '.jpg')
      File.join dir, "#{prefix}#{File.basename(name,'.dcm')}#{ext}"
    end

    def dicom_name_pattern(name, output_dir)
      dir = File.dirname(name)
      file = File.basename(name)
      number_pattern = /\d+/
      match = number_pattern.match(file)
      raise UnsupportedDICOM, "Invalid DICOM file name" unless match
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

    def define_transfer(options, *defaults)
      strategy, params = Array(options[:transfer])

      unless defaults.first.is_a?(Hash)
        default_strategy = defaults.shift.to_sym
      end
      defautl_strategy ||= :sample
      default_params = defaults.shift || {}
      raise "Invalid number of parametrs" unless defaults.empty?
      Transfer.strategy strategy || default_strategy, default_params.merge((params || {}).to_h)
    end

    def pixel_value_range(num_bits, signed)
      num_values = (1 << num_bits) # 2**num_bits
      if signed
        [-num_values/2, num_values/2-1]
      else
        [0, num_values-1]
      end
    end

    def dicom_element_value(dicom, tag, options = {})
      if dicom.exists?(tag)
        value = dicom[tag].value
        if options[:first]
          if value.is_a?(String)
            value = value.split('\\').first
          elsif value.is_a?(Array)
            value = value.first
          end
        end
        value = value.send(options[:convert]) if options[:convert]
        value
      else
        options[:default]
      end
    end

    # WL (window level)
    def dicom_window_center(dicom)
      # dicom.window_center.value.to_i
      dicom_element_value(dicom, '0028,1050', convert: :to_f, first: true)
    end

    # WW (window width)
    def dicom_window_width(dicom)
      # dicom.window_center.value.to_i
      dicom_element_value(dicom, '0028,1051', convert: :to_f, first: true)
    end

    def dicom_rescale_intercept(dicom)
      dicom_element_value(dicom, '0028,1052', convert: :to_f, default: 0)
    end

    def dicom_rescale_slope(dicom)
      dicom_element_value(dicom, '0028,1053', convert: :to_f, default: 1)
    end

    def dicom_bit_depth(dicom)
      # dicom.send(:bit_depth)
      dicom_element_value dicom, '0028,0100', convert: :to_i
    end

    def dicom_signed?(dicom)
      # dicom.send(:signed_pixels?)
      case dicom_element_value(dicom, '0028,0103', convert: :to_i)
      when 1
        true
      when 0
        false
      end
    end

    def dicom_stored_bits(dicom)
      # dicom.bits_stored.value.to_i
      dicom_element_value dicom, '0028,0101', convert: :to_i
    end

    def dicom_narray(dicom, options = {})
      if dicom.compression?
        img = dicom.image
        pixels = dicom.export_pixels(img, dicom.send(:photometry))
        na = NArray.to_na(pixels).reshape!(dicom.num_cols, dicom.num_rows)
        bits = dicom_bit_depth(dicom)
        signed = dicom_signed?(dicom)
        stored_bits = dicom_stored_bits(dicom)
        if stored_bits != Magick::MAGICKCORE_QUANTUM_DEPTH
          use_float = stored_bits < Magick::MAGICKCORE_QUANTUM_DEPTH
          if use_float
            na = na.to_type(NArray::SFLOAT)
            na.mul! 2.0**(stored_bits - Magick::MAGICKCORE_QUANTUM_DEPTH)
            na = na.to_type(NArray::INT)
          else
            na.mul! (1 << (stored_bits - Magick::MAGICKCORE_QUANTUM_DEPTH))
          end
        end
        if remap = options[:remap] || level = options[:level]
          intercept = dicom_rescale_intercept(dicom)
          slope     = dicom_rescale_slope(dicom)
          if intercept != 0 || slope != 1
            na.mul! slope
            na.add! intercept
          end
          if level
            if level.is_a?(Array)
              center, width = level
            else
              center = dicom_window_center(dicom)
              width  = dicom_window_width(dicom)
            end
            if center && width
              low = center - width/2
              high = center + width/2
              na[na < low] = low
              na[na > high] = high
            end
          end

          # Now we limit the output values range.
          # Note that we don't use:
          #   min, max = pixel_value_range(bits, signed)
          # because thats the limits for the stored values, but not for
          # the representation values we're computing here (which are
          # typically signed even if the storage is unsigned)
          # We coud use this, but that would have to be
          #   min, max = pixel_value_range(stored_bits, false)
          #   min = -max
          # but that requires some reviewing.
          # Maybe this shold be parameterized.
          min, max = -65535, 65535
          min_pixel_value = na.min
          if min
            if min_pixel_value < min
              offset = min_pixel_value.abs
              na.add! offset
            end
          end
          max_pixel_value = na.max
          if max
            if max_pixel_value > max
              factor = (max_pixel_value.to_f/max.to_f).ceil
              na.div! factor
            end
          end
        end

        na
      else
        dicom.narray options
      end
    end

    def assign_dicom_pixels(dicom, pixels)
      if dicom.compression?
        dicom.delete DICOM::PIXEL_TAG
      end
      dicom.pixels = pixels
    end

    def dicom_compression(dicom)
      ts = DICOM::LIBRARY.uid(dicom.transfer_syntax)
      ts.name if ts.compressed_pixels?
    end

    def terminal_size
      if $stdout.respond_to?(:tty?) && $stdout.tty? && $stdout.respond_to?(:winsize)
        $stdout.winsize
      else
        size = [ENV['LINES'] || ENV['ROWS'], ENV['COLUMNS']]
        if size[1].to_i > 0
          size
        else
          if defined?(Readline) && Readline.respond_to?(:get_screen_size)
            size = Readline.get_screen_size
            if size[1].to_i > 0
              size
            elsif ENV['ANSICON'] =~ /\((.*)x(.*)\)/
              size = [$2, $1]
              if size[1].to_i > 0
                size
              else
                [27, 80]
              end
            end
          end
        end
      end
    end

  end
end
