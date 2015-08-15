# Inserting/extracting DICOM metadata in video files with FFMpeg
#
# Example of use:
#
#   # Add metadata to a file
#   dicom = DICOM::DObject.read(dicom_file)
#   meta_codec = MetaCodec.new(mode: :chunked)
#   meta_file = 'ffmetadata'
#   meta_codec.write_metadata(dicom, meta_file, dx: 111, dy: 222, dz: 333)
#   input_file = 'video.mkv'
#   output_file = 'video_with_metadata.mkv'
#   `ffmpeg -i #{input_file} -i #{meta_file} -map_metadata 1 -codec copy #{output_file}`
#
#   # Extract metadata from a file
#   `ffmpeg -i #{output_file}  -f ffmetadata #{meta_file}`
#   dicom_elements, additional_values = meta_codec.read_metadata(meta_file)
#
class DicomS::MetaCodec

  # Two encoding modes:
  # * :chunked : use few metadata entries (dicom_0)
  #   that encode all the DICOM elements (several are used because there's a limit
  #   in the length of a single metadata entry)
  # * :individual : use individual metadata entries for each DICOM tag
  def initialize(options = {})
    @mode = options[:mode] || :individual
  end

  def encode_metadata(dicom, additional_metadata = {}, &blk)
    elements = dicom.elements.select{|e| !e.value.nil?}
    elements = elements.select(&blk) if blk
    elements = elements.map{|e| [e.tag, e.value]}
    case @mode
    when :chunked
      txt = elements.map{|tag, value| "#{inner_escape(tag)}#{VALUE_SEPARATOR}#{inner_escape(value)}"}.join(PAIR_SEPARATOR)
      chunks = in_chunks(txt, CHUNK_SIZE).map{|txt| escape(txt)}
      metadata = Hash[chunks.each_with_index.to_a.map(&:reverse)]
    else
      pairs = elements.map { |tag, value|
        group, tag = tag.split(',')
        ["#{group}_#{tag}", escape(value)]
      }
      metadata = Hash[pairs]
    end
    metadata.merge(additional_metadata)
  end

  # Write DICOM metatada encoded for FFMpeg into a metadatafile
  # The file can be attached to a video input_file with:
  #   `ffmpeg -i #{input_file} -i #{metadatafile} -map_metadata 1 -codec copy #{output_file}`
  def write_metadata(dicom, metadatafile, additional_metadata = {}, &blk)
    metadata = encode_metadata(dicom, additional_metadata, &blk)
    File.open(metadatafile, 'w') do |file|
      file.puts ";FFMETADATA1"
      metadata.each do |name, value|
        file.puts "dicom_#{name}=#{value}"
      end
    end
  end

  def decode_metadata(txt)
    txt = unescape(txt)
    data = txt.split(PAIR_SEPARATOR).map{|pair| pair.split(VALUE_SEPARATOR)}
    data = data.map{|tag, value| [inner_unescape(tag), inner_unescape(value)]}
    data.map{|tag, value|
      DICOM::Element.new(tag, value)
    }
  end

  # Can extract the metadatafile from a video input_file with:
  #   `ffmpeg -i #{input_file}  -f ffmetadata #{metadatafile}`
  def read_metadata(metadatafile)
    lines = File.read(metadatafile).lines[1..-1]
    lines = lines.reject { |line|
      line = line.strip
      line.empty? || line[0, 1] == '#' || line[0, 1] == ';'
    }
    chunks = []
    elements = []
    additional_metadata = {}
    lines.each do |line|
      key, value = line.strip.split('=')
      key = key.downcase
      if match = key.match(/\Adicom_(\d+)\Z/)
        i = match[1].to_i
        chunks << [i, value]
      elsif match = key.match(/\Adicom_(\h+)_(\h+)\Z/)
        group = match[1]
        tag = match[2]
        tag = "#{group},#{tag}"
        elements << DICOM::Element.new(tag, unescape(value))
      elsif match = key.match(/\Adicom_(.+)\Z/)
        additional_metadata[match[1].downcase.to_sym] = value # TODO: type conversion?
      end
    end
    if chunks.size > 0
      elements += decode_metadata(chunks.sort_by(&:first).map(&:last).join)
    end
    [elements, additional_metadata]
  end

  private

  def escape(txt)
    txt.to_s.gsub('\\', '\\\\').gsub('=', '\\=').gsub(';', '\\;').gsub('#', '\\#').gsub('\n', '\\\n')
  end

  def unescape(txt)
    txt.to_s.gsub('\\\\', '\\').gsub('\\=', '=').gsub('\\;', ';').gsub('\\#', '#').gsub('\\\n', '\n')
  end

  VALUE_SEPARATOR = '>'
  PAIR_SEPARATOR = '<'

  def inner_escape(txt)
    txt.to_s.gsub(VALUE_SEPARATOR, '[[METACODEC_VSEP]]').gsub(PAIR_SEPARATOR, '[[METACODEC_PSEP]]')
  end

  def inner_unescape(txt)
    txt.to_s.gsub('[[METACODEC_VSEP]]', VALUE_SEPARATOR).gsub('[[METACODEC_PSEP]]', PAIR_SEPARATOR)
  end

  CHUNK_SIZE = 800

  def in_chunks(txt, max_size=CHUNK_SIZE)
    # txt.chars.each_slice(max_size).map(&:join)
    txt.scan(/.{1,#{max_size}}/)
  end

end
