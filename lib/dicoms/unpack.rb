class DicomS
  ELEMENTS_TO_REMOVE = %w(0028,2110 0028,2112 0018,1151 0018,1152 0028,1055 7FE0,0000 7FE0,0010)

  # When generating DICOMs back:
  # Elements that must be replaced (because image format is not preserved)
  #   0002,0010     Transfer Syntax UID
  #                 replace by 1.2.840.10008.1.2.1 Implicit VR Little Endian
  #                 or maybe 1.2.840.10008.1.2: Implicit VR Little Endian: Default Transfer Syntax for DICOM
  # these should be removed if present:
  #   0028,2110       Lossy Image Compression
  #   0028,2112       Lossy Image Compression Ratio
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
  #   0028,0100     Bits Allocated        (keep if value size is maintained)
  #   0028,0101     Bits Stored           make = Bits Allocated
  #   0028,0102     High Bit              make = BIts Stored - 1
  #   0028,0103     Pixel Representation  0-unsigned 1-signed
  #   0028,1050     Window Center
  #   0028,1051     Window Width
  #   0028,1052     Rescale Intercept
  #   0028,1053     Rescale Slope
  #   0028,1054     Rescale Type
  #   0028,1055     Window Center & Width Explanation  - can be removed if present
  # elements that shouldn't vary:
  #   0028,0002     Samples per Pixel                   = 1
  #   0028,0004     Photometric Interpretation          = MONOCHROME2
  # also, these element should be removed (because Pixel data is set by assigning an image)
  #   7FE0,0000     Group Length    - can be omitted
  #   7FE0,0010     Pixel Data      - will be assigned by assigning an image
  # other varying elements that need further study: (vary in some studies)
  #   0002,0000     File Meta Information Group Length # drop this and 0002,0001?
  #   0002,0003     Media Storage SOP Instance UID
  #   0008,0018     SOP Instance UID

  def unpack(pack_file, options = {})
    options = CommandOptions[options]

    progress = Progress.new('unpacking', options)

    unpack_dir = options.path_option(:output,
      File.basename(pack_file, '.mkv')
    )
    FileUtils.mkdir_p unpack_dir

    prefix = File.basename(pack_file, '.mkv')
    output_file_pattern = File.join(unpack_dir, "#{prefix}-%3d.jpeg")

    progress.begin_subprocess 'extracting_images', -70
    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-hide_banner'
      option '-loglevel', 'quiet'
      option '-i', file: pack_file
      option '-q:v', 2
      file output_file_pattern
    end
    ffmpeg.run error_output: :separate
    check_command ffmpeg

    progress.begin_subprocess 'extracting_metadata', -10
    metadata_file = File.join(unpack_dir, 'metadata.txt')
    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-hide_banner'
      option '-loglevel', 'quiet'
      option '-i', file: pack_file
      option '-f', 'ffmetadata'
      file metadata_file
    end
    ffmpeg.run error_output: :separate
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
    # each slice,
    # and remove and replace values as stated above

    metadata_yaml = File.join(unpack_dir, 'metadata.yml')
    File.open(metadata_yaml, 'w') do |yaml|
      yaml.write metadata.to_yaml
    end

    if options[:dicom_output]
      dicom_directory = options.path_option(:dicom_output,
        'DICOM'
      )
      img_files = File.join(unpack_dir, "#{prefix}-*.jpeg")
      progress.begin_subprocess 'generating_dicoms', 100, img_files.size
      count = 0
      pos = 0.0
      slice_pos = 0.0
      Dir[img_files].each do |fn, i|
        count += 1
        dicom_file = File.join(dicom_directory, File.basename(fn, '.jpeg')+'.dcm')
        dicom = DICOM::DObject.new
        dicom_elements.each do |element|
          case element.tag
          when '0002,0010'
            # TODO: replace value by 1.2.840.10008.1.2.1
          when *ELEMENTS_TO_REMOVE
            element = nil
          when '0020,0013'
            element.value = count
          when '0020,0032'
            if count == 1
              pos = element.value.split('\\').map(&:to_f)
            else
              pos[2] += metadata.dz
              element.value = pos.join('\\')
            end
          when '0020,1041'
            if count == 1
              slice_pos = element.value.to_f
            else
              slice_pos += metadata.dz
              element.value = slice_pos.to_f
            end
          when '0028,0101'
            element.value = metadata.bits
          when '0028,0102'
            element.value = metadata.bits - 1
          when '0028,0103'
            element.value = metadata.signed ? 1 : 0
          end
          if element
            Element.new(element.tag, element.value, :parent => dicom)
          end
        end
        image = Magick::Image::read(fn).first
        d.pixels = image_to_dicom_pixels(metadata, image)
        dicom.write dicom_file
        progress.update_subprocess count
      end
    end
    progress.finish
  end

  def image_to_dicom_pixels(metadata, image)
    min_v = metadata.min # value assigned to black
    max_v = metadata.max # value assigned to white
    if metadata.rescaled
      slope = metadata.slope
      intercept = metadata.intercept
      if slope != 1 || intercept != 0
        # unscale
        min_v = (min_v - intercept)/slope
        max_v = (max_v - intercept)/slope
      end
    end
    pixels = image.export_pixels(0, 0, image.columns, image.rows, 'I')
    pixels =  NArray.to_na(pixels).reshape!(image.columns, image.rows)
    pixels = pixels.to_type(NArray::SFLOAT)
    q = Magick::MAGICKCORE_QUANTUM_DEPTH
    min_p, max_p = pixel_value_range(q, false)
    # min_p => min_v; max_p => max_v
    # pixels.sbt! min_p # not needed, min_p should be 0
    pixels.mul! (max_v - min_v).to_f/(max_p - min_p)
    pixels.add! min_v
    bits = metadata.bits # original bit depth, in accordance with '0028,0100' if dicom metatada present
    signed = metadata.signed # in accordance with 0028,0103 if dicom metadata
    if true
      pixels = pixels.to_i
    else
      if bits > 16
        if signed
          pixels = pixels.to_type(3) # sint (signed, four bytes)
        else
          pixels = pixels.to_type(4) # sfloat (single precision float)
        end
      elsif bits > 8
        if signed
          pixels = pixels.to_type(2) # int (signed, two bytes)
        else
          pixels = pixels.to_type(3) # sint (signed, four bytes)
        end
      elsif signed
        pixels = pixels.to_type(2) # sint (signed, two bytes)
      else
        pixels = pixels.to_type(1) # byte (unsiged)
      end
    end
    pixels
  end
end
