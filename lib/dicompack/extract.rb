class DicomPack
  # extract the images of a set of DICOM files
  def extract(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    pack_dir = options[:output] || File.join(dicom_directory, 'images')

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
    # TODO: save metadata as yml/JSON in pack_dir
    pack_dir
  end
end
