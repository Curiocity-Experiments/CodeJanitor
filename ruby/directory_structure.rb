#!/usr/bin/env ruby
require 'set'
require 'optparse'
require 'colorize'

# Ensure 'colorize' gem is installed
begin
  require 'colorize'
rescue LoadError
  puts "Installing 'colorize' gem..."
  system('gem install colorize')
  Gem.clear_paths
  require 'colorize'
end

# Default ignore patterns
IGNORE_PATTERNS = Set.new(['node_modules', 'vendor', 'tmp', 'log', 'public/packs', 'coverage', 'dist', 'build'])

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: directory_structure.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-iPATTERN", "--ignore=PATTERN", "Additional ignore pattern (can be used multiple times)") do |pattern|
    IGNORE_PATTERNS.add(pattern)
  end

  opts.on("-nDEPTH", "--depth=DEPTH", Integer, "Maximum depth to traverse (default: 3)") do |depth|
    options[:depth] = depth
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

# Function to parse .gitignore
def parse_gitignore(dir, ignore_patterns)
  gitignore = File.join(dir, '.gitignore')
  if File.exist?(gitignore)
    File.readlines(gitignore).each do |line|
      line.strip!
      next if line.empty? || line.start_with?('#')
      ignore_patterns.add(line)
    end
  end
  ignore_patterns
end

# Function to determine if a path should be ignored
def ignored?(relative_path, ignore_patterns)
  ignore_patterns.any? do |pattern|
    File.fnmatch?(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
  end
end

# Function to traverse directories and build table data
def traverse(dir, current_depth, max_depth, ignore_patterns, table, current_row)
  return if current_depth > max_depth
  entries = Dir.children(dir).sort
  entries.each do |entry|
    path = File.join(dir, entry)
    relative_path = path.sub(/^#{Regexp.escape(Dir.pwd)}/, '').sub(/^\//, '')
    next if ignored?(relative_path, ignore_patterns)
    if File.directory?(path)
      # Initialize new row if needed
      table[current_depth] ||= []
      table[current_depth] << entry.colorize(:blue).bold + "/"
      traverse(path, current_depth + 1, max_depth, ignore_patterns, table, current_row + 1)
    else
      # Initialize new row if needed
      table[current_depth] ||= []
      table[current_depth] << entry.colorize(:green)
    end
  end
end

# Parse .gitignore and add to ignore patterns
IGNORE_PATTERNS = parse_gitignore(target_dir, IGNORE_PATTERNS)

# Initialize table data structure
table = {}
traverse(target_dir, 0, max_depth, IGNORE_PATTERNS, table, 0)

# Print as table
puts "\nDirectory Structure for #{target_dir}".cyan.bold
puts "-" * (25 + target_dir.length)
(0..max_depth).each do |level|
  next unless table[level]
  row = table[level].join(" | ")
  puts row
end
puts "-" * (25 + target_dir.length) + "\n\n"
