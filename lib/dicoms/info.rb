require 'fileutils'

class DicomS
  def info(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end
    if options[:output]
      if File.directory?(dicom_directory)
        output_dir = options[:output]
      else
        output_file = options[:output]
        if File.exists?(output_file)
          raise "File #{output_file} already exits"
        end
        output = File.open(output_file, 'w')
      end
    end
    if output_dir
      FileUtils.mkdir_p output_dir
      dicom_files.each do |file|
        output_file = File.join(output_dir, File.basename(file,'.dcm')+'.txt')
        File.open(output_file, 'w') do |output|
          dicom = DICOM::DObject.read(file)
          print_info dicom, output
        end
      end
    else
      dicom_files.each do |file|
        dicom = DICOM::DObject.read(file)
        print_info dicom, output || STDOUT
      end
      output.close if output
    end
  end

  def print_info(dicom, output)
    $stdout = output
    dicom.print_all
    $stdout = STDOUT
  end
end
