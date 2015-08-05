require 'thor'

class DicomPack
  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    desc 'version', "Display dicompack version"
    map %w(-v --version) => :version
    def version
      say "dicompack #{VERSION}"
    end

    class_option 'verbose', type: :boolean, default: false

    desc "pack DICOM-DIR", "pack a DICOM directory"
    option :output,   desc: 'output file', aliases: '-o'
    option :tmp,      desc: 'temporary directory'
    option :strategy, desc: 'dynamic range strategy', aliases: '-s', default: 'sample'
    def pack(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      strategy_parameters = {
        drop_base: true
      }
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      packer = DicomPack.new(settings)
      packer.pack(
        dicom_dir,
        strategy_parameters.merge(
          strategy:  options.strategy.to_sym,
          output: options.output,
          tmp:  options.tmp
        )
      )
      # rescue => raise Error?
      0
    end

    desc "unpack DICOMPACK", "unpack a dicompack file"
    option :output,   desc: 'output directory', aliases: '-o'
    def unpack(dicompack)
      DICOM.logger.level = Logger::FATAL
      unless File.file?(dicompack)
        raise Error, set_color("File not found: #{dicompack}", :red)
        say options
      end
      settings = {} # TODO: ...
      packer = DicomPack.new(settings)
      packer.unpack dicompack
      # rescue => raise Error?
      0
    end

    desc "extract DICOM-DIR", "extract images from a set of DICOM files"
    option :output,   desc: 'output directory', aliases: '-o'
    option :strategy, desc: 'dynamic range strategy', aliases: '-s', default: 'sample'
    def pack(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      strategy_parameters = {
        drop_base: true
      }
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      packer = DicomPack.new(settings)
      packer.extract(
        dicom_dir,
        strategy_parameters.merge(
          strategy:  options.strategy.to_sym,
          output: options.output,
        )
      )
      # rescue => raise Error?
      0
    end

    desc "Level stats", "Level limits of one or more DICOM files"
    def stats(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      dicompack = DicomPack.new(settings)
      stats = dicompack.stats dicom_dir
      puts "Aggregate values for #{stats[:n]} DICOM files:"
      puts "  Minimum level: #{stats[:min]}"
      puts "  Next minimum level: #{stats[:next_min]}"
      puts "  Maximum level: #{stats[:max]}"
      0
    end

    desc "projection DICOM-DIR", "extract projected images from a DICOM sequence"
    option :output,   desc: 'output directory', aliases: '-o'
    option :strategy, desc: 'dynamic range strategy', aliases: '-s', default: 'window' # TODO: min max for fixed, etc.
    option :axial,    desc: 'axial projection (N for single slice, mip, aap for aggregation, * for all)'
    option :sagittal, desc: 'sagittal projection (N for single slice, mip, aap for aggregation, * for all)'
    option :coronal,    desc: 'coronal projection (N for single slice, mip, aap for aggregation, * for all)'
    def projection(dicom_dir)
      DICOM.logger.level = Logger::FATAL
      settings = {} # TODO: ...
      unless File.directory?(dicom_dir)
        raise Error, set_color("Directory not found: #{dicom_dir}", :red)
        say options
      end
      packer = DicomPack.new(settings)
      packer.projection(
        dicom_dir,
        {
          strategy:  options.strategy.to_sym,
          output: options.output,
          axial: options.axial == 'axial' ? 'mip' : options.axial,
          sagittal: options.sagittal == 'sagittal' ? 'mip' : options.sagittal,
          coronal: options.coronal == 'coronal' ? 'mip' : options.coronal
        }
      )
      # rescue => raise Error?
      0
    end

  end
end
