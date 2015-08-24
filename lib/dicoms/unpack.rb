class DicomS
  # TODO: option for pack to restore DICOM files;
  #
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
    # each slice

    metadata_yaml = File.join(unpack_dir, 'metadata.yml')
    File.open(metadata_yaml, 'w') do |yaml|
      yaml.write metadata.to_yaml
    end

    # progress.begin_subprocess 'generating_dicoms', 100
    # ...
    progress.finish
  end
end
