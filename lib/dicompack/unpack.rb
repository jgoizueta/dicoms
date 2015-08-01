class DicomPack
  def unpack(pack_file, options = {})
    unpack_dir = options[:output] || File.basename(pack_file, '.mkv')
    FileUtils.mkdir_p unpack_dir

    prefix = File.basename(pack_file, '.mkv')
    output_file_pattern = File.join(unpack_dir, "#{prefix}-%3d.jpeg")

    ffmpeg = SysCmd.command('ffmpeg', @ffmpeg_options) do
      option '-hide_banner'
      option '-loglevel', 'quiet'
      option '-i', file: pack_file
      option '-q:v', 2
      file output_file_pattern
    end
    ffmpeg.run error_output: :separate
    check_command ffmpeg

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
  end
end
