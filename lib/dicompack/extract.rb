class DicomPack
  # extract the images of a set of DICOM files
  def extract(dicom_directory, options = {})
    progress = Progress.new('extracting', options)
    progress.begin_subprocess 'reading_metadata', 2

    strategy = define_transfer(options, :window)
    sequence = Sequence.new(dicom_directory, transfer: strategy)

    progress.begin_subprocess 'extracting_images', 100, sequence.size
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
      progress.update_subprocess i
    end
    # TODO: save sequence.metadata as yml/JSON in pack_dir
    extract_dir
    progress.finish
  end
end
