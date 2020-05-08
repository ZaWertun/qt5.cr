#!/usr/bin/env crystal

# This script downloads all sources of all supported Qt5 versions, and then
# proceed to generate all bindings for all configured platforms.
#
# This script is what the `ready-to-use` branches are built by.

require "file_utils"
require "colorize"
require "ini"

configurations = [
#      OS       LIBC   ARCH      Qt     Clang target triplet      Ptr  Endian
  { "linux", "gnu", "x86_64", "5.5",  "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.6",  "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.7",  "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.8",  "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.9",  "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.10", "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.11", "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.12", "x86_64-unknown-linux-gnu", 8, "little" },
  { "linux", "gnu", "x86_64", "5.13", "x86_64-unknown-linux-gnu", 8, "little" },
]

TEMPDIR = File.expand_path("#{__DIR__}/../download_cache")

struct QtVersion
  getter name : String
  delegate to_s, to: @name

  def initialize(@name)
  end

  def file_name
    if major == 5 && minor >= 10
      "qt-everywhere-src-#{@name}.0"
    else
      "qt-everywhere-opensource-src-#{@name}.0"
    end
  end

  def download_url
    "https://download.qt.io/archive/qt/#{@name}/#{@name}.0/single/#{file_name}.tar.xz"
  end

  def archive_path
    "#{TEMPDIR}/#{file_name}.tar.xz"
  end

  def path
    "#{TEMPDIR}/#{file_name}"
  end

  private def major
    @name.split('.')[0].to_i
  end

  private def minor
    @name.split('.')[1].to_i
  end
end

class TargetPlatform
  getter os : String
  getter libc : String
  getter arch : String
  getter qt : QtVersion
  getter triple : String
  getter pointer_size : Int32
  getter endian : String

  property dir : String
  property qmake : String
  property libs_dir : String
  property include_dir : String?

  def initialize(@os, @libc, @arch, qt, @triple, @pointer_size, @endian)
    @qt = QtVersion.new(qt)
    @dir = @qt.path
    @qmake = "#{@qt.path}/qtbase/bin/qmake"
    @libs_dir = "#{@qt.path}/qtbase/libs"
    @include_dir = nil
  end

  def target
    "#{@os}-#{@libc}-#{@arch}-qt#{@qt}"
  end

  def env
    {
      "QTDIR" => @dir,
      "QMAKE" => @qmake,
      "QT_LIBS_DIR" => @libs_dir,
      "TARGET_TRIPLE" => @triple,
      "BINDING_PLATFORM" => target,
    }
    .tap {|h| h["QT_INCLUDE_DIR"] = @include_dir.not_nil! if @include_dir }
  end
end

def report(current, total, message)
  cur_s = (current + 1).to_s
  total_s = total.to_s

  step_s = "#{cur_s.ljust(total_s.size)}/#{total_s}".colorize.mode(:bold)
  puts "(#{step_s})  #{message}"
end

def report_step(message)
  puts "=> #{message}".colorize.mode(:bold)
end

def download_missing_qts(versions)
  urls = versions
    .reject{|v| File.file? v.archive_path}
    .map{|v| v.download_url}

  if urls.empty?
    report_step "All Qt sources already present"
    return
  end

  arguments = [ "--remote-name-all", "--location" ] + urls

  report_step "Downloading missing Qt sources (#{versions.map{|v|v.name}.join(", ")})"
  Dir.cd TEMPDIR do
    system("curl", arguments)
  end
end

def unpack_qts(versions)
  files = versions
    .reject{|v| Dir.exists? v.path}
    .map{|v| v.archive_path}

  if files.empty?
    report_step "All Qt sources already unpacked"
    return
  end

  report_step "Unpacking Qt sources"
  files.each_with_index do |file, idx|
    report(idx, files.size, "Unpacking #{file}")
    system("tar", [ "-C", TEMPDIR, "-xf", file ])
  end
end

def get_qt_modules_from_gitmodules(version)
  # This is actually how they're aggregating which modules exist in `qt.pro`
  modules_file = "#{version.path}/.gitmodules"

  if File.exists? modules_file
    data = INI.parse File.read(modules_file)
    data
      .reject{|_, v| v["qt"]? == "false"}
      .map{|k, _| k[/submodule "qt(.*)"/, 1]?}
  end
end

def get_qt_modules_from_qtpro(version)
  # For Qt5.5 and below
  pro_file = "#{version.path}/qt.pro"

  if File.exists? pro_file
    File.read_lines(pro_file)
      .select(/^addModule\(qt/)
      .map{|x| x[/addModule\(qt([^,)]+)/, 1]?}
      .to_a
  end
end

def get_qt_modules(version) : Array(String)
  modules = get_qt_modules_from_gitmodules(version)
  modules ||= get_qt_modules_from_qtpro(version)

  if modules
    modules
      .compact
      .select{|name| Dir.exists?("#{version.path}/qt#{name}")}
  else
    Array(String).new
  end
end

def configure_qts(versions)
  keep_modules = { "base" }
  list = versions.reject{|v| File.executable? "#{v.path}/qtbase/bin/qmake"}

  if list.empty?
    report_step "All Qt sources already configured"
    return
  end

  report_step "Configuring Qt versions"
  list.each_with_index do |qt, idx|
    report(idx, list.size, "Configuring Qt#{qt}")

    skip_modules = get_qt_modules(qt).reject{|x| keep_modules.includes? x}
    skip_args = skip_modules.flat_map{|x| [ "-skip", x ]}

    Dir.cd qt.path do
      system( # Build QMake of this version
        "./configure",
        [
          "-opensource", "-confirm-license",
          "-nomake", "examples",
          "-nomake", "tests",
          "-nomake", "tools",
          "-prefix", "#{qt.path}/qtbase",
        ] + skip_args,
      )

      unless $?.success?
        STDERR.puts "Failed to configure Qt#{qt} in #{qt.path} - Abort."
        exit 2
      end
    end

    # Use QMake to generate all missing include files
    system("make", [ "-C", qt.path, "qmake_all" ])

    unless $?.success?
      STDERR.puts "Failed to generate headers for Qt#{qt} in #{qt.path} - Abort."
      exit 2
    end
  end
end

# Kick off
FileUtils.mkdir_p(TEMPDIR)
platforms = [configurations.last].map{|x| TargetPlatform.new(*x)}
versions = platforms.map(&.qt).uniq

SYSTEM = ARGV.includes?("--system")

if SYSTEM
  query = `qmake -query 2>/dev/null`
  query = `qmake-qt5 -query 2>/dev/null` if query.empty?
  raise "Can't find qmake/qmake-qt5 executable in PATH" if query.empty?

  dir : String? = nil
  version : String? = nil
  libs_dir : String? = nil
  include_dir : String? = nil
  query.each_line do |l|
    case l
    when /QT_INSTALL_PREFIX:(.+)/
      dir = $1
    when /QT_INSTALL_HEADERS:(.+)/
      include_dir = $1
    when /QT_INSTALL_LIBS:(.+)/
      libs_dir = $1
    when /QT_VERSION:(.+)\.\d+/
      version = $1
    else
    end
  end

  platform = TargetPlatform.new(
      "linux", "gnu", "x86_64", version.not_nil!, "x86_64-unknown-linux-gnu", 8, "little"
  ).tap do |p|
    p.dir = dir.not_nil!
    p.libs_dir = libs_dir.not_nil!
    p.include_dir = include_dir.not_nil!
  end

  platforms = [platform]
else
  # Download and unpack Qt sources
  download_missing_qts(versions)
  unpack_qts(versions)
  configure_qts(versions)
end

# Run bindgen for all configured platforms
report_step "Generating bindings for all platforms"
platforms.each_with_index do |platform, idx|
  env = platform.env

  args = [ # Arguments to bindgen
    "qt.yml",
    "--var", "architecture=#{platform.arch}",
    "--var", "libc=#{platform.libc}",
    "--var", "os=#{platform.os}",
    "--var", "pointersize=#{platform.pointer_size}",
    "--var", "endian=#{platform.endian}",
  ]

  report(idx, platforms.size, "Generating #{platform.target}")
  bindgen = Process.run( # Run bindgen
    command: "lib/bindgen/tool.sh",
    args: args,
    env: env,
    shell: false,
    output: STDOUT,
    error: STDERR,
  )

  unless bindgen.success?
    STDERR.puts "Failed to build #{platform.target} using Qt#{platform.qt} on #{platform.triple} - Abort."
    exit 1
  end
end
