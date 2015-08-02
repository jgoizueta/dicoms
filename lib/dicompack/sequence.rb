require 'matrix'

class DicomPack
  # Sequence of DICOM CT/MRI slices
  # Metadata about the sequence including the orientation of RCS
  # (patient coordinate system) in relation to the DICOM sequence
  # reference. This is given as three vectors xaxis yaxis and zaxis.
  #
  # The RCS system consists of the axes X, Y, Z:
  #
  # * X increases from Right to Left of the patient
  # * Y increases from the Anterior to the Posterior side
  # * Z increases from the Inferior to the Superior side
  #
  # (Inferior/Superior are sometimes referred to as Bottom/Top or Feet/Head)
  #
  # The xaxis vector is an unitary vector in the X direction
  # projected in the DICOM reference system x, y, z axes.
  # Similarly, yaxis and zaxis are unitary vectors in the Y and
  # Z directions projected into the DICO reference system.
  #
  # The DICOM reference uses these axes:
  #
  # * x left to right pixel matrix column
  # * y top to bottom pixel matrix row
  # * z first to last slice
  #
  # The most common orientation for CT is:
  #
  #  * xaxis: 1,0,0
  #  * yaxis: 0,1,0
  #  * zaxis: 0,0,-1
  #
  # In this case, the X and Y axes are coincident with x an y of the
  # DICOM reference and slices are ordered in decreasing Z value.
  #
  class Sequence
    def initialize(dicom_directory, options = {})
      @files = find_dicom_files(dicom_directory)
      if @files.empty?
        raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
      end
      @visitors = Array(options[:visit])
      @metadata = nil
      compute_metadata! options[:strategy]
    end

    attr_reader :files
    attr_accessor :metadata

    include Support

    def size
      @files.size
    end

    def dicom(i)
      # TODO: support caching strategies for reading as DICOM objects:
      #       no-caching, max-size cache, ...
      dicom = DICOM::DObject.read(@files[i])
      send dicom, i, *@visitors
      dicom
    end

    def first
      dicom(0)
    end

    def last
      dicom(size-1)
    end

    def each(&blk)
      (0...@files.size).each do |i|
        dicom = dicom(i)
        send dicom, i, blk
      end
    end

    private

    def compute_metadata!(strategy)
      # TODO: with stored metadata option, if metadata exist in dicom dir, use it
      # and store it first time it is computed

      first_i = nil
      last_i = nil
      first_md = last_md = nil
      lim_min = lim_max = nil

      @visitors.push -> (dicom, i) {
        if !first_i || first_i > i
          first_i = i
          first_md = single_dicom_metadata(dicom)
        elsif !last_i || last_i < i
          last_i = i
          last_md = single_dicom_metadata(dicom)
        end
        unless last_i
          last_i = first_i
          last_md = first_md
        end
        unless first_i
          first_i = last_i
          first_md = first_md
        end
        unless lim_min
          lim_min, lim_max = DynamicRangeStrategy.min_max_limits(dicom)
        end
      }

      metadata = Settings[]

      if strategy
        min, max = strategy.min_max(self)
        metadata.merge! min: min, max: max
      end

      # make sure at least two different DICOM files are visited
      if first_i == last_i
        last
        if first_i == last_i
          first
        end
      end
      # TODO: remove slice_z from metadata...

      if false
        # always visit first and last slice
        first unless first_i == 0
        last  unless last_i  == size - 1
        # TODO: change metadata :x, :y, :z by max-min ranges or remove
      end

      metadata.lim_min = lim_min
      metadata.lim_max = lim_max

      @visitors.pop

      total_n = size

      n = last_i - first_i

      xaxis = decode_vector(first_md.xaxis)
      yaxis = decode_vector(first_md.yaxis)
      # assert xaxis == decode_vector(last_md.xaxis)
      # assert yaxis == decode_vector(last_md.yaxis)
      first_pos = Vector[*first_md.to_h.values_at(:x, :y, :z)]
      last_pos = Vector[*last_md.to_h.values_at(:x, :y, :z)]
      zaxis = xaxis.cross_product(yaxis)
      d = last_pos - first_pos
      zaxis = -zaxis if zaxis.inner_product(d) < 0

      metadata.merge! Settings[first_md]
      metadata.zaxis = encode_vector zaxis
      metadata.nz = total_n
      metadata.dz = (last_md.slice_z - first_md.slice_z).abs/n

      @metadata = metadata
    end

    def send(dicom, i, *visitors)
      if dicom
        visitors.each do |visitor|
          if visitor
            if visitor.arity == 1
              visitor[dicom]
            elsif visitor.arity == 2
              visitor[dicom, i]
            elsif visitor.arity == 3
              visitor[dicom, i, @files[i]]
            end
          end
        end
      end
    end

  end
end
