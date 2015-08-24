class DicomS
  def stats(dicom_directory, options = {})
    # TODO: compute histogram of levels
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    mins = []
    maxs = []
    next_mins = []
    n = 0

    dicom_files.each do |file|
      n += 1
      d = DICOM::DObject.read(file)
      data = dicom_narray(d)
      min = data.min
      mins << min
      maxs << data.max
      next_mins << data[data > min].min
    end
    {
      n: n,
      min: mins.min,
      next_min: next_mins.min,
      max: maxs.max
    }
  end
end
