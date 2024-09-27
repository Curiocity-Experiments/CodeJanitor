#!/usr/bin/env ruby
# directory_structure.rb

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


puts "Directory Structure Analysis: Provides an overview of the project's file organization.".cyan
puts "This helps developers understand the project layout and locate important components.".cyan
puts ""

# Default ignore patterns
DEFAULT_IGNORE_PATTERNS = Set.new(['node_modules', '.git', 'vendor', 'tmp', 'log', 'public/packs', 'coverage', 'dist', 'build'])

def parse_gitignore(dir)
  gitignore_file = File.join(dir, '.gitignore')
  return [] unless File.exist?(gitignore_file)

  File.readlines(gitignore_file).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
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
def traverse(dir, current_depth, max_depth, ignore_patterns, table, target_dir)
  return if current_depth > max_depth
  entries = Dir.children(dir).sort
  entries.each do |entry|
    path = File.join(dir, entry)
    relative_path = path.sub(/^#{Regexp.escape(target_dir)}/, '').sub(/^\//, '')
    next if ignored?(relative_path, ignore_patterns)
    table[current_depth] ||= []
    if File.directory?(path)
      table[current_depth] << entry.colorize(:blue).bold + "/"
      traverse(path, current_depth + 1, max_depth, ignore_patterns, table, target_dir) if current_depth < max_depth
    end
  end
end

total_files = Dir.glob(File.join(target_dir, '**', '*')).select { |f| File.file?(f) }.count
total_directories = Dir.glob(File.join(target_dir, '**', '*')).select { |f| File.directory?(f) }.count

puts "\nProject Overview:".cyan
puts "Total Files: #{total_files}".green
puts "Total Directories: #{total_directories}".green
puts "-" * 50 + "\n\n"

# Parse .gitignore and add to ignore patterns
ignore_patterns = parse_gitignore(target_dir, DEFAULT_IGNORE_PATTERNS.dup)

# Initialize table data structure
table = {}
traverse(target_dir, 0, max_depth, ignore_patterns, table, target_dir)

# Print as table
puts "\n===Directory Structure for #{target_dir}===".cyan.bold
puts "-" * 50
max_width = table.values.flatten.map(&:length).max
(0..max_depth).each do |level|
  next unless table[level]
  indent = "  " * level
  table[level].each do |entry|
    puts "#{indent}#{entry.ljust(max_width)}"
  end
end
puts "-" * 50 + "\n\n"
