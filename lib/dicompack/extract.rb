class DicomPack
  # extract the images of a set of DICOM files
  def extract(dicom_directory, options = {})
    strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
    sequence = Sequence.new(dicom_directory, strategy: strategy)

    extract_dir = options[:output] || File.join(dicom_directory, 'images')
    FileUtils.mkdir_p FileUtils.mkdir_p extract_dir
    prefix = nil
    min, max = sequence.metadata.min, sequence.metadata.max
    sequence.each do |d, i, file|
      unless prefix
        prefix, name_pattern, start_number = dicom_name_pattern(file, extract_dir)
      end
      output_image = output_file_name(extract_dir, prefix, file)
      sequence.save_jpg d, output_image
    end
    # TODO: save sequence.metadata as yml/JSON in pack_dir
    extract_dir
  end
end
