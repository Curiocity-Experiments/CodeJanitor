#!/usr/bin/env ruby
# identify_key_files.rb

require 'optparse'
require 'colorize'

def menu_info
  {
    title: "Identify Key Files",
    description: "Finds and lists the most important files in your project."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end


puts "Key Files Identification: Locates crucial project files.".cyan
puts "This helps developers quickly find and access important project components.".cyan
puts ""

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: identify_key_files.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

target_dir = options[:directory] || Dir.pwd

unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

Dir.chdir(target_dir)

puts "=== Key Files Identification ===".yellow.bold

# Detect project type
if File.exist?("Gemfile")
  project_type = "Rails/Ruby Project"
elsif Dir.glob("*.gemspec").any?
  project_type = "Ruby Gem"
else
  project_type = "Unknown Ruby Project"
end

puts "Detected Project Type: #{project_type}".cyan

# Define key files based on project type
key_files = case project_type
when "Rails/Ruby Project"
  %w[
    Gemfile Gemfile.lock Rakefile config.ru
    config/application.rb config/environment.rb config/routes.rb config/database.yml
    app/controllers/application_controller.rb
    bin/rails bin/rake
    README.md
  ]
when "Ruby Gem"
  gemspec_files = Dir.glob("*.gemspec")
  [
    "Gemfile",
    *gemspec_files,
    "lib/#{File.basename(Dir.pwd)}.rb",
    "README.md",
    "LICENSE.txt",
    "Rakefile",
    "spec/spec_helper.rb"
  ]
else
  %w[
    Gemfile Rakefile README.md LICENSE.txt
    lib/ spec/
  ]
end

# Check each key file
key_files.each do |file|
  if File.exist?(file) || Dir.exist?(file)
    puts "✅ Found: #{file}".green
  else
    puts "❌ Missing: #{file}".red
  end
end

puts "===================================".yellow.bold
