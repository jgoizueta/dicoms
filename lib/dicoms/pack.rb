class DicomS
  def pack(dicom_directory, options = {})
    # TODO: keep more metadata to restore the exact strategy+min,max and so
    # be able to restore original DICOM values (and rescaling/window metadata)
    # bit depth, signed/unsigned, rescale, window, data values corresponding
    # to minimum (black) and maximum (white)
    options = CommandOptions[options]

    progress = Progress.new('packing', options)
    progress.begin_subprocess 'reading_metadata', 2

    strategy = define_transfer(options, :sample)
    sequence = Sequence.new(dicom_directory, transfer: strategy, roi: options[:roi])

    output_name = (options[:output] || File.basename(dicom_directory)) + '.mkv'
    pack_dir = options.path_option(:tmp, 'dspack_tmp') # TODO: better default
    FileUtils.mkdir_p pack_dir

    name_pattern = start_number = prefix = nil

    progress.begin_subprocess 'extracting_images', 60, sequence.size
    image_files = []
    keeping_path do
      sequence.each do |d, i, file|
        unless name_pattern
          prefix, name_pattern, start_number = dicom_name_pattern(file, pack_dir)
        end
        output_image = output_file_name(pack_dir, prefix, file)
        image_files << output_image
        sequence.save_jpg d, output_image
        progress.update_subprocess i
      end
    end
    if options[:dicom_metadata]
      metadata_file = File.join(pack_fir, 'ffmetadata')
      # TODO: filter-out elements to be ignored
      meta_codec.write_metadata(DICOM::DObject.read(dicom_files.first), metadata_file, sequence.metadata.to_h)
    end
    progress.begin_subprocess 'packing_images'
    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-y' # overwrite existing files
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
        sequence.metadata.each do |key, value|
          option '-metadata', "dicom_#{key}", equal_value: value
        end
      end
      file output_name
    end
    ffmpeg.run error_output: :separate
    check_command ffmpeg
    if File.expand_path(File.dirname(output_name)) == File.expand_path(pack_dir)
      image_files.files.each do |file|
        FileUtils.rm file
      end
    else
      FileUtils.rm_rf pack_dir
    end
    progress.finish
  end
end
