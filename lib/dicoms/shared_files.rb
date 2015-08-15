require 'yaml'
require 'json'

class DicomS

  # Shared files can be concurrently accessed by diferent processes.
  # They should never be large files, and update operations (reading,
  # then writing) should always be quick, because processes trying to
  # read the file while an update is going on are blocked.
  #
  # Example
  #
  #    counter = SharedFile.new('counter')
  #
  #    counter.update do |contents|
  #      contents.to_i + 1
  #    end
  #
  #    counter = counter.read.to_i
  #
  class SharedFile
    def initialize(name, options = {})
      @name = name
      raise "A directory exists with that name" if File.directory?(@name)
    end

    attr_reader :name

    def exists?
      File.exists?(@name)
    end

    #  Update a file safely.
    def update(&blk)
      File.open(@name, File::RDWR|File::CREAT, 0644) do |file|
        file.flock File::LOCK_EX
        if blk.arity == 1
          new_contents = blk.call(file.read)
        else
          new_contents = blk.call
        end
        file.rewind
        file.write new_contents
        file.flush
        file.truncate file.pos
      end
    end

    #  Read a file safely
    def read
      File.open(@name, "r") do |file|
        file.flock File::LOCK_SH # this blocks until available
        file.read
      end
    end

    def write(contents)
      update { contents }
    end
  end
end
