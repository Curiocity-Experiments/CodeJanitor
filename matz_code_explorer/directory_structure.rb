#!/usr/bin/env ruby
# directory_structure.rb

require 'set'
require 'optparse'

# Ensure 'colorize' gem is installed
begin
  require 'colorize'
rescue LoadError
  puts "Error: 'colorize' gem is not installed. Please run `gem install colorize` to continue."
  exit 1
end

def menu_info
  {
    title: "Directory Structure Analysis",
    description: "Analyzes the directory structure of your project for better organization."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end

# Show usage if no options are provided
if ARGV.empty?
  puts "Usage: directory_structure.rb [options]"
  puts "Use -h or --help for more information."
  exit
end

# Default ignore patterns
DEFAULT_IGNORE_PATTERNS = Set.new(['node_modules', '.git', 'vendor', 'tmp', 'log', 'public/packs', 'coverage', 'dist', 'build'])

def parse_gitignore(dir, ignore_patterns)
  gitignore_file = File.join(dir, '.gitignore')
  return ignore_patterns unless File.exist?(gitignore_file)

  File.readlines(gitignore_file).each do |line|
    line.strip!
    next if line.empty? || line.start_with?('#')
    ignore_patterns.add(line)
  end
  ignore_patterns
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: directory_structure.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-iPATTERN", "--ignore=PATTERN", "Additional ignore pattern (can be used multiple times)") do |pattern|
    DEFAULT_IGNORE_PATTERNS.add(pattern)
  end

  opts.on("--override-ignore=FILE", "Override default ignore patterns with those from FILE") do |file|
    DEFAULT_IGNORE_PATTERNS.clear
    File.readlines(file).each { |line| DEFAULT_IGNORE_PATTERNS.add(line.strip) unless line.start_with?('#') }
  end

  opts.on("-nDEPTH", "--depth=DEPTH", Integer, "Maximum depth to traverse (default: 3)") do |depth|
    options[:depth] = depth
  end

  opts.on("-r", "--recent", "Highlight recently modified files and directories") do
    options[:recent] = true
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

target_dir = options[:directory] || Dir.pwd
max_depth = options[:depth] || 3

unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

# Function to determine if a file should be ignored
def ignored?(relative_path, ignore_patterns)
  ignore_patterns.any? do |pattern|
    File.fnmatch?(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
  end
end

# Function to traverse directories and build table data
def traverse(dir, current_depth, max_depth, ignore_patterns, summary, target_dir, total_files_dirs, recent_files)
  return if current_depth > max_depth

  entries = Dir.children(dir).sort
  entries.each do |entry|
    path = File.join(dir, entry)
    relative_path = path.sub(/^#{Regexp.escape(target_dir)}\//, '')

    if File.directory?(path)
      total_files_dirs[:directories] += 1
      summary[current_depth][:directories] << entry if summary[current_depth]
      traverse(path, current_depth + 1, max_depth, ignore_patterns, summary, target_dir, total_files_dirs, recent_files) if current_depth < max_depth
    elsif File.file?(path)
      next if ignored?(relative_path, ignore_patterns)
      total_files_dirs[:files] += 1
      recent_files << relative_path if File.mtime(path) > (Time.now - 7 * 24 * 60 * 60)
      summary[current_depth][:files] << entry if summary[current_depth]
    end
  end
end

# Initialize summary data structure
total_files_dirs = { files: 0, directories: 0 }
recent_files = []
summary = Hash.new { |hash, key| hash[key] = { directories: [], files: [] } }

# Parse .gitignore and add to ignore patterns
ignore_patterns = parse_gitignore(target_dir, DEFAULT_IGNORE_PATTERNS.dup)

# Traverse and collect data
traverse(target_dir, 0, max_depth, ignore_patterns, summary, target_dir, total_files_dirs, recent_files)

# Print overview
puts "\n#{'=' * 60}".cyan
puts "Project Overview".cyan.bold.center(60)
puts "#{'=' * 60}".cyan
puts "Total Files: #{total_files_dirs[:files]}".green
puts "Total Directories: #{total_files_dirs[:directories]}".green
puts "#{'-' * 60}".cyan

# Print recently modified files if requested
if options[:recent]
  puts "\nRecently Modified Files (Last 7 Days):".magenta.bold
  recent_files.take(10).each do |file|
    puts "  #{file}".magenta
  end
  puts "(Showing first 10 of #{recent_files.size} recent files)" if recent_files.size > 10
  puts "#{'-' * 60}".cyan
end

# Print directory structure summary
puts "\n=== Directory Summary for #{target_dir} ===".cyan.bold
puts "#{'-' * 60}".cyan
summary.each do |level, data|
  indent = "  " * level
  data[:directories].each do |directory|
    puts "#{indent}#{directory.colorize(:blue).bold}/"
  end
  data[:files].take(5).each do |file|
    puts "#{indent}#{file.colorize(:light_yellow)}"
  end
  puts "#{indent}... (#{data[:files].size - 5} more files)" if data[:files].size > 5
end
puts "#{'-' * 60}".cyan + "\n\n"
