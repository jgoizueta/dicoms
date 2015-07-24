require 'thor'

class DicomPack
  class CLI < Thor
    desc "pack DICOM-DIR", "pack a DICOM directory"
    def pack(dicom_dir, output = nil)
    end

    desc "unpack DICOMPACK", "unpack a dicompack file"
    def unpack(dicompack, output_dir = nil)
    end
  end
end
