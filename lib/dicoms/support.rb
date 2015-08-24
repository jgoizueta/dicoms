require 'matrix'

class DicomS
  USE_SLICE_Z = false
  METADATA_TYPES = {
    dx: :to_f, dy: :to_f, dz: :to_f,
    nx: :to_i, ny: :to_i, nz: :to_i,
    max: :to_i, min: :to_i
  }

  module Support
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
        match = /\d+/.match(File.basename(name))
        if match
          numeric_files << [match[0], name]
        else
          non_numeric << name
        end
      end
      numeric_files.sort_by{ |text, name| text.to_i }.map(&:last) + non_numeric.sort
    end

    def single_dicom_metadata(dicom)
      dx, dy = dicom.pixel_spacing.value.split('\\').map(&:to_f)
      x, y, z = dicom.image_position_patient.value.split('\\').map(&:to_f)
      xx, xy, xz, yx, yy, yz = dicom.image_orientation_patient.value.split('\\').map(&:to_f)
      if USE_SLICE_Z
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
            na.mul! (1 << (stored_bits - Magick::MAGIsCKCORE_QUANTUM_DEPTH))
          end
        end
        min, max = pixel_value_range(bits, signed)
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
  end
end
