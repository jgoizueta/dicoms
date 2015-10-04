require 'matrix'

class DicomS
  # DICOM series containing a sequence of CT/MRI image slices.
  #
  # The following metadata about the series is computed:
  #
  # * min: pixel value corresponding to the minimum output level
  # * max: pixel value corresponding to the maximum output level
  # * rescaled: 1 means that min and max are photometrically rescaled
  #   values; 0 means they are internal raw values.
  # * slope, intercept: photometric rescaling parameters.
  # * lim_min, lim_max: (raw) output enconding range limits
  # * bits: bit-depth of the original pixel values
  # * signed: 1-pixels values are signed 0-unsigned
  # * firstx: first X coordinate (slice number) of the ROI
  # * lastx: lastt X coordinate (slice number) of the ROI
  # * firsty: first Y coordinate of the ROI
  # * lasty: last Y coordinate of the ROI
  # * lastz:lastt Z coordinate of the ROI
  # * study_id, series_id: identification of the patient's study/series
  # * dx, dy, dz: voxel spacing (dx, dy is pixel spacing; dz is the slice spacing)
  # * x, y, z: image position (in RCS; see below)
  # * xaxis, yaxis, zaxis: each is a three-component vector defining an axis
  #   of the image orientation (see below) (encoded as comma-separated string)
  # * slice_z: slice position
  # * nx: number of columns
  # * ny: number of rows
  # * nz: number of slices
  # * reverse_x 1 means the X axis is reversed (from RCS)
  # * reverse_y 1 means the Y axis is reversed (from RCS)
  # * reverse_< 1 means the Z axis is reversed (from RCS)
  # * axial_sx scale factor: horizontal reduction of axial projections
  # * axial_sy scale factor: vertical reduction of axial projections
  # * coronal_sx scale factor: horizontal reduction of coronal projections
  # * coronal_sy scale factor: vertical reduction of coronal projections
  # * sagittal_sx scale factor: horizontal reduction of sagittal projections
  # * sagittal_sy scale factor: vertical reduction of sagittal projections
  #
  # Orientation of RCS
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
      @roi = options[:roi]
      @files = find_dicom_files(dicom_directory)
      @visitors = Array(options[:visit])
      @visited = Array.new(@files.size)
      @metadata = nil
      @strategy = options[:transfer]
      @metadata = Settings[version: 'DSPACK1']

      # TODO: reuse existing metadata in options (via settings)

      if options[:reorder]
        # don't trust the file ordering; use the instance number to ordering
        # this requires reading all the files in advance
        compute_metadata! true
      else
        # if information about the series size (nx, ny, nz)
        # and the axis orientation (reverse_x, reverse_y, reverse_z)
        # is available here we can set the @roi now and avoid
        # processing slices outside it. (in that case the
        # metadata won't consider those slices, e.g. for minimum/maximum
        # pixel values)
        if options[:nx] && options[:ny] && options[:nz] &&
           options.to_h.has_key?(:reverse_x) &&
           options.to_h.has_key?(:reverse_y) &&
           options.to_h.has_key?(:reverse_z)
          @metadata.merge!(
            nx: options[:nx], ny: options[:ny], nz: options[:nz],
            reverse_x: options[:reverse_x],
            reverse_y: options[:reverse_y],
            reverse_z: options[:reverse_z]
          )
          set_cropping_volume!
          cropping_set = true
        end
        compute_metadata!
      end

      set_cropping_volume! unless cropping_set
    end

    attr_reader :files, :strategy
    attr_accessor :metadata
    attr_reader :image_cropping

    def transfer
      @strategy
    end

    include Support

    def size
      @files.size
    end

    def dicom(i)
      # TODO: support caching strategies for reading as DICOM objects:
      #       no-caching, max-size cache, ...
      dicom = DICOM::DObject.read(@files[i])
      sop_class = dicom['0002,0002'].value
      unless sop_class == '1.2.840.10008.5.1.4.1.1.2'
        raise UnsupportedDICOM, "Unsopported SOP Class #{sop_class}"
      end
      # TODO: require known SOP Class:
      # (in tag 0002,0002, Media Storage SOP Class UID)

      visit dicom, i, *@visitors
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
        visit dicom, i, blk
      end
    end

    def save_jpg(dicom, filename)
      keeping_path do
        image = dicom_image(dicom)
        image.write(filename)
      end
    end

    def dicom_image(dicom)
      if dicom.is_a?(Magick::Image)
        image = dicom
      else
        if @strategy
          image = @strategy.image(dicom, metadata.min, metadata.max)
        else
          image = dicom.image
        end
      end
      if DICOM.image_processor == :mini_magick
        image.format('jpg')
      end
      if @image_cropping
        @image_cropping.inspect
        firstx, lastx, firsty, lasty = @image_cropping
        image.crop! firstx, firsty, lastx-firstx+1, lasty-firsty+1
      end
      image
    end

    # To use the pixels to be directly saved to an image,
    # use the `:unsigned` option to obtain usigned intensity values.
    # If the pixels are to be assigned as Dicom pixels
    # ('Dicom#pixels=') they don't need to be unsigned.
    def dicom_pixels(dicom, options = {})
      if @strategy
        pixels = @strategy.pixels(dicom, metadata.min, metadata.max)
      else
        pixels = dicom_narray(dicom, level: false, remap: true)
      end
      if @image_cropping
        firstx, lastx, firsty, lasty = @image_cropping
        pixels = pixels[firstx..lastx, firsty..lasty]
      end
      if options[:unsigned] && metadata.lim_min < 0
        pixels.add! -metadata.lim_min
      end
      pixels
    end

    # Check if the images belong to a single series
    def check_series
      visit_all
      @visited.reject { |name, study, series, instance| study == @metadata.study_id && series == @metadata.series_id }.empty?
    end

    def reorder!
      # This may invalidate dz and the cropped selection of slices
      visit_all
      @visited.sort_by! { |name, study, series, instance| [study, series, instance] }
      @files = @visited.map { |name, study, series, instance| name }
    end

    def needs_reordering?
      visit_all
      @visited.sort_by! { |name, study, series, instance| [study, series, instance] }
      @files != @visited.map { |name, study, series, instance| name }
    end

    private

    def compute_metadata!(all = false)
      first_i = nil
      last_i = nil
      first_md = last_md = nil
      lim_min = lim_max = nil
      study_id = series_id = nil
      bits = signed = nil
      slope = intercept = nil

      @visitors.push -> (dicom, i, filename) {
        unless @visited[i]
          unless lim_min
            if @strategy
              lim_min, lim_max = @strategy.min_max_limits(dicom)
            else
              lim_min, lim_max = Transfer.min_max_limits(dicom)
            end
          end
          if bits
            if bits != dicom_bit_depth(dicom) || signed != dicom_signed?(dicom)
              raise InvalidDICOM, "Inconsistent slices"
            end
          else
            bits   = dicom_bit_depth(dicom)
            signed = dicom_signed?(dicom)
          end
          if slope
            if slope != dicom_rescale_slope(dicom) || intercept != dicom_rescale_intercept(dicom)
              raise InvalidDICOM, "Inconsitent slices"
            end
          else
            slope = dicom_rescale_slope(dicom)
            intercept = dicom_rescale_intercept(dicom)
          end
          slice_study_id  = dicom.study_id.value # 0020,0010 SH (short string)
          slice_series_id = dicom.series_number.value.to_i # 0020,0011 IS (integer string)
          slice_image_id  = dicom.instance_number.value.to_i # 0020,0013 IS (integer string)
          study_id  ||= slice_study_id
          series_id ||= slice_series_id
          @visited[i] = [filename, slice_study_id, slice_series_id, slice_image_id]
          if !first_i || @visited[first_i].last > slice_image_id
            first_i = i
            first_md = single_dicom_metadata(dicom)
          elsif !last_i || @visited[last_i].last < slice_image_id
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
        end
      }

      if @strategy
        min, max = @strategy.min_max(self)
        rescaled = @strategy.min_max_rescaled?
      else
        min, max = [lim_min, lim_max]
        rescaled = false
      end

      @metadata.merge! min: min, max: max, rescaled: rescaled ? 1 : 0
      @metadata.merge! bits: bits, signed: signed ? 1 : 0
      @metadata.merge! slope: slope, intercept: intercept

      if all
        reorder!
        first_i = 0
        lsat_i = @files.size - 1
      end

      # make sure at least two different DICOM files are visited
      if first_i == last_i
        last
        if first_i == last_i
          first
        end
      end
      # TODO: remove slice_z from @metadata...

      if false
        # always visit first and last slice
        first unless first_i == 0
        last  unless last_i  == size - 1
        # TODO: change @metadata :x, :y, :z by max-min ranges or remove
      end

      @metadata.merge! study_id: study_id, series_id: series_id
      @metadata.lim_min = lim_min
      @metadata.lim_max = lim_max

      total_n = size

      xaxis = decode_vector(first_md.xaxis)
      yaxis = decode_vector(first_md.yaxis)
      # assert xaxis == decode_vector(last_md.xaxis)
      # assert yaxis == decode_vector(last_md.yaxis)
      first_pos = Vector[*first_md.to_h.values_at(:x, :y, :z)]
      last_pos = Vector[*last_md.to_h.values_at(:x, :y, :z)]
      zaxis = xaxis.cross_product(yaxis)
      d = last_pos - first_pos
      zaxis = -zaxis if zaxis.inner_product(d) < 0

      @metadata.merge! Settings[first_md]
      @metadata.zaxis = encode_vector zaxis
      @metadata.nz = total_n
      # Position coordinates are assumed at the voxel's center
      # note that we divide the coordinate span z_last - z_first
      # by the number of slices (voxels) minus one
      @metadata.dz = (last_md.slice_z - first_md.slice_z).abs/(last_i - first_i)

      tolerance = 0.05
      if (xaxis.map(&:abs) - Vector[1,0,0]).magnitude > tolerance ||
         (yaxis.map(&:abs) - Vector[0,1,0]).magnitude > tolerance ||
         (zaxis.map(&:abs) - Vector[0,0,1]).magnitude > tolerance
        raise UnsupportedDICOM, "Unsupported orientation"
      end
      @metadata.reverse_x = (xaxis[0] < 0) ? 1 : 0
      @metadata.reverse_y = (yaxis[1] < 0) ? 1 : 0
      @metadata.reverse_z = (zaxis[2] < 0) ? 1 : 0
    end

    def set_cropping_volume!
      if @roi
        if @roi.size == 6
          first_x, last_x, first_y, last_y, first_z, last_z = @roi.map(&:round)
        else
          xrange, yrange, zrange = @roi
          first_x = xrange.first
          last_x = xrange.last
          last_x -= 1 if xrange.exclude_end?
          first_y = yrange.first
          last_y = yrange.last
          last_y -= 1 if yrange.exclude_end?
          first_z = zrange.first
          last_z = zrange.last
          last_z -= 1 if zrange.exclude_end?
        end
        x1, x2 = first_x, last_x
        y1, y2 = first_y, last_y
        z1, z2 = first_z, last_z
        if @metadata.reverse_x == 1
          x1, x2 = [x1, x2].map { |x| metadata.nx - x }.sort
        end
        if @metadata.reverse_y == 1
          y1, y2 = [y1, y2].map { |y| metadata.ny - y }.sort
        end
        if @metadata.reverse_z == 1
          z1, z2 = [z1, z2].map { |z| metadata.nz - z }.sort
        end
        @image_cropping = [x1, x2, y1, y2]
        @selected_slices = (z1..z2)
        @files = @files[@selected_slices]
        @visited = @visited[@selected_slices]
        @metadata.merge!(
          firstx: first_x, lastx: last_x,
          firsty: first_y, lasty: last_y,
          firstz: first_z, lastz: last_z
        )
      end
    end

    def visit_all
      @visited.each_with_index do |data, i|
        dicom(i) unless data
      end
    end

    def visit(dicom, i, *visitors)
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
