#!/usr/bin/env ruby
# documentation_check.rb

require 'optparse'
require 'colorize'

MENU_INFO = {
  title: "Documentation Analysis",
  description: "Assesses the project's documentation coverage."
}.freeze

def detect_project_type
  if File.exist?("Gemfile")
    "Rails/Ruby Project"
  elsif Dir.glob("*.gemspec").any?
    "Ruby Gem"
  else
    "Unknown Ruby Project"
  end
end

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: documentation_check.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = File.expand_path(dir)
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end

option_parser.parse!

if options.empty? && ARGV.empty?
  puts option_parser
  exit 1
end

target_dir = options[:directory] || ARGV[0] || Dir.pwd

unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

puts "Documentation Analysis: Assesses the project's documentation coverage.".cyan
puts "This helps ensure the codebase is well-documented for better maintainability.".cyan
puts ""

puts "=== Documentation and README Analysis ===".yellow.bold

Dir.chdir(target_dir) do
  # Detect project type
  project_type = detect_project_type
  puts "Detected Project Type: #{project_type}".cyan

  # Check for README files
  readme_files = Dir.glob('{README,README.*}', File::FNM_CASEFOLD)
  if readme_files.empty?
    puts "❌ No README file found.".red
  else
    puts "✅ Found README files:".green
    readme_files.each { |file| puts "  - #{file}".green }
  end

  # Define documentation directory based on project type
  doc_dir = project_type == "Ruby Gem" ? "doc" : "docs"

  # Check for documentation directory
  if Dir.exist?(doc_dir)
    puts "✅ '#{doc_dir}' directory exists.".green
    doc_count = Dir.glob("#{doc_dir}/**/*").select { |f| File.file?(f) }.count
    puts "   Found #{doc_count} files in the documentation directory.".green
  else
    puts "❌ No '#{doc_dir}' directory found.".red
  end

  # Check for YARD or RDoc comments
  ruby_files = Dir.glob('**/*.rb')
  documented_files = ruby_files.select do |file|
    begin
      File.readlines(file).any? { |line| line.match?(/^\s*#/) }
    rescue => e
      puts "Warning: Unable to read #{file} - #{e.message}".yellow
      false
    end
  end

  if ruby_files.empty?
    puts "No Ruby files found in the target directory.".red
  else
    puts "\nDocumentation coverage:".cyan
    puts "Total Ruby files: #{ruby_files.count}".green
    puts "Files with comments: #{documented_files.count}".green
    coverage = (documented_files.count.to_f / ruby_files.count * 100).round(2)
    puts "Documentation coverage: #{coverage}%".send(coverage >= 50 ? :green : :yellow)
  end
end

puts "===================================".yellow.bold
