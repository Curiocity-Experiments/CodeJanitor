#!/usr/bin/env ruby
# identify_key_files.rb

require 'optparse'
require 'colorize'

# Constants for Key Files
KEY_FILES_RAILS = %w[
  Gemfile Gemfile.lock Rakefile config.ru
  config/application.rb config/environment.rb config/routes.rb config/database.yml
  app/controllers/application_controller.rb
  bin/rails bin/rake
  README.md
].freeze

KEY_FILES_RUBY_GEM = %w[
  Gemfile Rakefile README.md LICENSE.txt
  lib/ spec/
].freeze

# Method to handle displaying information about the tool
def menu_info
  {
    title: "Identify Key Files",
    description: "Find and list essential files in your project to ensure completeness and ease onboarding."
  }
end

# Method to parse arguments and return options
def parse_arguments
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: identify_key_files.rb [options]"

    opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
      options[:directory] = dir
    end

    opts.on("-h", "--help", "Displays Help") do
      display_help_and_info(opts)
      exit
    end

    opts.on("--info", "Displays information about the tool") do
      display_help_and_info(opts)
      exit
    end
  end.parse!

  if ARGV.length == 1 && Dir.exist?(ARGV[0])
    options[:directory] = ARGV[0]
  elsif ARGV.empty?
    display_help_and_info
    exit
  end

  options
end

# Method to display help and info
def display_help_and_info(opts = nil)
  if opts
    puts opts
  else
    puts "Usage: identify_key_files.rb [options]"
  end
  info = menu_info
  puts "\n#{info[:title]}"
  puts info[:description]
end

# Method to determine the project type
def detect_project_type(target_dir)
  if File.exist?(File.join(target_dir, "Gemfile"))
    "Rails/Ruby Project"
  elsif Dir.glob(File.join(target_dir, "*.gemspec")).any?
    "Ruby Gem"
  else
    "Unknown Ruby Project"
  end
end

# Method to get the Ruby version used in the target directory
def get_ruby_version(target_dir)
  version_file = File.join(target_dir, ".ruby-version")
  return File.read(version_file).strip if File.exist?(version_file)

  "Unknown"
end

# Method to get the key files list based on the project type and Ruby version
def get_key_files_list(project_type, target_dir)
  ruby_version = get_ruby_version(target_dir)
  case project_type
  when "Rails/Ruby Project"
    ruby_version >= "2.5" ? KEY_FILES_RAILS : KEY_FILES_RAILS - ["bin/rails", "bin/rake"]
  when "Ruby Gem"
    gemspec_files = Dir.glob(File.join(target_dir, "*.gemspec"))
    [
      "Gemfile",
      *gemspec_files,
      "lib/#{File.basename(target_dir)}.rb",
      "README.md",
      "LICENSE.txt",
      "Rakefile",
      "spec/spec_helper.rb"
    ]
  else
    KEY_FILES_RUBY_GEM
  end
end

# Method to check if key files exist and print the results
def check_key_files(key_files, target_dir)
  puts "\n=== Key Files for: #{target_dir} ===".yellow.bold

  missing_files = []
  key_files.each do |file|
    full_path = File.join(target_dir, file)
    if File.exist?(full_path) || Dir.exist?(full_path)
      puts "  ✔ #{file}".green
    else
      missing_files << file
    end
  end

  provide_recommendations(missing_files, target_dir) unless missing_files.empty?
end

# Method to provide recommendations based on the results
def provide_recommendations(missing_files, target_dir)
  puts "\nSuggestions: Add missing files to complete the project.".cyan.bold
  puts "\n| Missing File                 | Reason                                             |".light_blue
  puts "|-----------------------------|-----------------------------------------------------|".light_blue
  missing_files.each do |file|
    reason = case file
             when "Gemfile" then "Defines the project's dependencies. Essential for reproducibility."
             when "Gemfile.lock" then "Locks dependencies to specific versions, ensuring consistency."
             when "Rakefile" then "Defines automation tasks. Useful for simplifying project operations."
             when "config.ru" then "Used for Rack-based web servers. Required for deployment."
             when "config/application.rb" then "Sets up configuration for a Rails application. Crucial for initialization."
             when "config/environment.rb" then "Defines Rails environment settings. Needed for proper bootstrapping."
             when "config/routes.rb" then "Manages URL routing. Fundamental for directing requests."
             when "config/database.yml" then "Configures database connections. Necessary for data persistence."
             when "app/controllers/application_controller.rb" then "Base controller for other controllers. Helps maintain DRY code."
             when "bin/rails" then "Provides Rails command-line tools. Facilitates development workflows."
             when "bin/rake" then "Provides Rake command-line tasks. Simplifies task automation."
             when "README.md" then "Describes the project. Important for onboarding and documentation."
             when "LICENSE.txt" then "Defines legal use of the code. Important for open-source compliance."
             when "lib/" then "Contains core modules and libraries. Central to application functionality."
             when "spec/" then "Holds test files. Vital for ensuring code quality."
             else "General project structure file."
             end
    puts "| #{file.ljust(29).red} | #{reason.ljust(50).green} |"
  end

  puts "\nThese files ensure your project is functional, maintainable, and easy for new developers to understand.".cyan
end

# Main script execution
options = parse_arguments

target_dir = options[:directory] || Dir.pwd

# Defensive Programming: Ensure target directory exists and is valid
unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

puts "\n🚀 Identifying Key Files for Your Project...".cyan.bold

project_type = detect_project_type(target_dir)
ruby_version = get_ruby_version(target_dir)
puts "Project Type: #{project_type}".magenta
puts "Ruby Version: #{ruby_version}".magenta

key_files = get_key_files_list(project_type, target_dir)
check_key_files(key_files, target_dir)

# Explanation for different outputs when run on different folders
puts "\n💡 Tip: Different projects have different key files. This script helps identify what's missing for each type, whether Rails, a gem, or another Ruby project.".cyan.bold
