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

    def dicom_slope_intercept(dicom)
      intercept_element = dicom['0028,1052']
      intercept = intercept_element ? intercept_element.value.to_i : 0
      slope_element = dicom['0028,1053']
      slope = slope_element ? slope_element.value.to_i : 1
      [slope, intercept]
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
  end
end
