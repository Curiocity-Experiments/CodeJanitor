#!/usr/bin/env ruby
# dependency_analysis.rb

require 'json'
require 'bundler'
require 'optparse'
require 'colorize' # Provides colored output to make messages stand out

# Function that provides meta information about the script
# Useful for displaying brief details about what the script does
# Onboarding developers can use '--info' to get a quick overview
# of the purpose of this script.
def menu_info
  {
    title: "Dependency Analysis",
    description: "Examines project dependencies and versions."
  }
end

# Handle the '--info' flag to display script metadata for onboarding
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end

# Inform the user about the script's purpose - helpful for new developers
puts "Dependency Analysis: Examines project dependencies and versions.".cyan
puts "This helps manage external libraries and identify potential conflicts or outdated packages.".cyan
puts ""

options = {}
# Define command-line options that the script accepts
# This helps to make the script flexible and allows developers to analyze a different directory if needed
OptionParser.new do |opts|
  opts.banner = "Usage: dependency_analysis.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

# Set the target directory to analyze
# If no directory is provided via the command line, the current directory is used by default
target_dir = options[:directory] || Dir.pwd

# Ensure that the provided directory exists before proceeding
unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

# Indicate the start of dependency analysis - helpful for visual clarity
puts "=== Dependency Analysis ===".yellow.bold

Dir.chdir(target_dir) do
  # Analyze Bundler dependencies from the Gemfile
  # Gemfile is used by Bundler to manage dependencies for a project
  if File.exist?('Gemfile')
    puts "Bundler Dependencies: (analyzing dependencies defined in the Gemfile)".cyan
    begin
      # Load the Bundler environment to access dependency information
      Bundler.with_unbundled_env do
        bundler = Bundler.load
        if bundler.dependencies.empty?
          # Inform the user that no dependencies were found in the Gemfile
          puts "  No Bundler dependencies found. Please check if your Gemfile is configured correctly.".yellow
        else
          # List each dependency found in the Gemfile
          bundler.dependencies.each do |dep|
            puts "  - #{dep.name} (#{dep.requirement})".green
          end
          puts "
Action: Review the listed dependencies to ensure they are up-to-date and compatible with your project requirements.".cyan
        end
      end
    rescue => e
      # Handle potential errors, such as missing or corrupt Gemfile
      puts "  Error loading Gemfile: #{e.message}. Please verify the integrity of your Gemfile.".red
    end
  else
    puts "Gemfile not found. Make sure you have a Gemfile in the project root to define dependencies.".yellow
  end

  # Analyze `.gemspec` files for dependencies
  # Gemspec files are typically used for Ruby libraries/gems and define their dependencies
  gemspec_files = Dir.glob('*.gemspec')
  if gemspec_files.any?
    puts "\nGemspec Dependencies: (analyzing dependencies defined in gemspec files)".cyan
    gemspec_files.each do |gemspec|
      puts "  #{File.basename(gemspec)}:".cyan
      File.readlines(gemspec).each do |line|
        # Look for lines that specify dependencies in the gemspec
        if line =~ /add_(?:development_|runtime_)?dependency/
          puts "  - #{line.strip}".green
        end
      end
    end
    puts "
Action: Review the gemspec dependencies to confirm they align with the intended functionality of the gem.".cyan
  else
    puts "\nNo gemspec files found. If this is a gem project (such as a library intended for distribution), you will need a properly defined .gemspec file to specify the gem's dependencies and metadata. Otherwise, a .gemspec file is not needed for standard applications.".yellow
  end

  # End of analysis - helps visually indicate completion
  puts "===================================".yellow.bold
  puts "
Analysis Complete: Review the output above for any missing or outdated dependencies. Ensure all dependencies are properly defined and compatible.".cyan
end
