class DicomPack
  def pack(dicom_directory, options = {})
    # TODO: keep more metadata to restore the exact strategy+min,max and so
    # be able to restore original DICOM values (and rescaling/window metadata)
    # bit depth, signed/unsigned, rescale, window, data values corresponding
    # to minimum (black) and maximum (white)

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
      option '-loglevel', 'quiet'
      option '-hide_banner'
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
    ffmpeg.run error_output: :separate
    check_command ffmpeg
  end
end
