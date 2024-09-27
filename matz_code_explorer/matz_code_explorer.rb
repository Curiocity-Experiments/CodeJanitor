#!/usr/bin/env ruby
# matz_code_explorer.rb

require 'optparse'
require 'colorize'
require 'tty-prompt'
require 'json'

puts "=== Matz's Joyful Code Explorer ===".yellow.bold
puts "Let's embark on a delightful journey through your Ruby project!".cyan
puts "We'll uncover insights that'll make you smile and your code shine.".cyan
puts " "

# Initialize options hash
options = {
  ignore_patterns: []
}

# Parse command-line options
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] <path_to_analyze>"

  opts.on("-h", "--help", "Display this friendly help message") do
    puts opts
    exit
  end

  opts.on("--log", "Enable logging to a file (for keepsakes!)") do
    options[:log_enabled] = true
  end

  opts.on("-i", "--ignore PATTERN", "Add an ignore pattern (use multiple times for more fun!)") do |pattern|
    options[:ignore_patterns] << pattern
  end

  opts.on("-v", "--verbose", "Enable verbose logging") do
    options[:verbose] = true
  end
end.parse!

# Get the target directory from the arguments
target_dir = ARGV.pop

# Validate the target directory
unless target_dir && Dir.exist?(target_dir)
  puts "Oops! We need a valid path to explore. Let's try again!".red
  puts "Usage: #{$0} [options] <path_to_analyze>".yellow
  exit 1
end

# Determine the directory where the main script resides
script_dir = File.dirname(__FILE__)

# Initialize log_file as nil to prevent undefined variable errors
log_file = nil

# Setup logging if enabled
if options[:log_enabled]
  timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
  log_file = File.join(script_dir, "joyful_analysis_#{timestamp}.log")
  File.open(log_file, 'w') do |file|
    file.puts "=== Matz's Joyful Code Explorer Log ===".yellow.bold
    file.puts "Date: #{Time.now}"
    file.puts "Target Directory: #{target_dir}"
    file.puts "Ignore Patterns: #{options[:ignore_patterns].join(', ')}"
    file.puts "-" * 40
  end
  $stdout.reopen(log_file, "a")
  $stderr.reopen(log_file, "a")
  puts "Log File (for posterity!): #{log_file}".green
end

# Function to run a given script with appropriate arguments
def run_script(script_name, target_dir, ignore_patterns)
  ignore_options = ignore_patterns.map { |p| "-i '#{p}'" }.join(' ')
  command = "ruby #{script_name} -d '#{target_dir}' #{ignore_options}"
  system(command)
end

# List of scripts to include in the explorer
scripts = [
  "directory_structure.rb",
  "identify_key_files.rb",
  "dependency_analysis.rb",
  "code_metrics.rb",
  "documentation_check.rb",
  "ownership_insights.rb",
  "security_analysis.rb"
]

# Ensure 'tty-prompt' is installed
begin
  require 'tty-prompt'
rescue LoadError
  puts "Installing tty-prompt gem for a more interactive experience...".yellow
  system('gem install tty-prompt')
  Gem.clear_paths
  require 'tty-prompt'
end

puts "Target Directory: #{target_dir}".cyan
puts "=" * 40

# Initialize TTY::Prompt
prompt = TTY::Prompt.new

# Function to fetch menu info from a script
def fetch_menu_info(script_path)
  info = {}
  # Execute the script with '--info' and capture output
  output = `ruby "#{script_path}" --info 2>/dev/null`
  lines = output.strip.split("\n")
  if lines.size >= 2
    info[:title] = lines[0]
    info[:description] = lines[1]
  else
    info[:title] = File.basename(script_path, '.rb')
    info[:description] = "No description available."
  end
  info
end

# Build script choices with titles and descriptions
script_choices = []

# Add each script with its title and description
scripts.each do |script|
  script_path = File.join(script_dir, script)
  if File.exist?(script_path)
    info = fetch_menu_info(script_path)
    # Assign name and description separately
    script_choices << { name: info[:title], value: script, desc: info[:description] }
  else
    script_choices << { name: "#{File.basename(script, '.rb')} (Missing)", value: script, disabled: true }
  end
end

# Add "Run All Scripts" option at the top
script_choices.unshift({ name: "Run All Scripts", value: :run_all })

# Add "Cancel" option at the end
script_choices << { name: "Cancel", value: :cancel }

begin
  # Present the multi-select menu to the user
  selected = prompt.multi_select(
    "Which delightful scripts shall we run? (Use Space to select, Enter to confirm)",
    script_choices,
    per_page: 10,
    cycle: true,
    help: "Use ↑/↓ arrows to navigate, Space to select, Enter to confirm."
  )
rescue TTY::Reader::InputInterrupt, Interrupt
  puts "\nOperation interrupted by user. Exiting gracefully...".red
  exit
end

# Handle "Run All Scripts" selection
if selected.include?(:run_all)
  selected = scripts
  puts "\nAll scripts have been selected!".green
end

# Handle "Cancel" selection
if selected.include?(:cancel)
  puts "\nNo worries! Maybe another time. Have a fantastic day exploring!".cyan
  exit
end

# Remove "Run All Scripts" and "Cancel" from selection if present
selected.delete(:run_all)
selected.delete(:cancel)

# Function to get the project's Ruby version
def get_project_ruby_version(target_dir)
  ruby_version_file = File.join(target_dir, '.ruby-version')
  if File.exist?(ruby_version_file)
    File.read(ruby_version_file).strip
  else
    `ruby -v`.split[1]
  end
end

# Exit gracefully if no scripts are selected
if selected.empty?
  puts "\nNo scripts selected. Exiting gracefully. Maybe next time!".yellow
  exit
end

puts "\n=== Let the joyful exploration begin! ===".yellow.bold

# Execute each selected script
selected.each do |script|
  script_path = File.join(script_dir, script)
  if File.exist?(script_path)
    if run_script(script_path, target_dir, options[:ignore_patterns])
      puts "✅ #{File.basename(script, '.rb')} ran successfully.".green
      puts " "
    else
      puts "💔 #{File.basename(script, '.rb')} stumbled a bit. Let's show it some love later!".red
    end
  else
    puts "🕵️ Hmm, we couldn't find #{File.basename(script, '.rb')}. The mystery deepens!".red
  end
end

# Function to gather analysis summary
def get_analysis_summary(scripts, script_dir)
  total_scripts = scripts.count
  scripts_ran = scripts.count { |s| File.exist?(File.join(script_dir, s)) }
  scripts_missing = scripts.count { |s| !File.exist?(File.join(script_dir, s)) }

  {
    total_scripts: total_scripts,
    scripts_ran: scripts_ran,
    scripts_missing: scripts_missing
  }
end

# Compile the summary
summary = get_analysis_summary(scripts, script_dir)

# Function to get the project's Ruby version
def get_project_ruby_version(target_dir)
  ruby_version_file = File.join(target_dir, '.ruby-version')
  if File.exist?(ruby_version_file)
    File.read(ruby_version_file).strip
  else
    `ruby -v`.split[1]
  end
end

# Display the summary
puts "\n=== Joyful Repository Analysis Summary ===".yellow.bold
puts "Project Ruby Version: #{get_project_ruby_version(target_dir)}".cyan
puts "Total scripts in our toolbox: #{summary[:total_scripts]}".cyan
puts "Scripts we ran: #{summary[:scripts_ran]}".green
puts "Scripts that need a hug: #{summary[:scripts_missing]}".red
puts "========================================".yellow.bold

puts "\nOur code exploration adventure has concluded!".green.bold
puts "May your code bring you joy and your bugs be few!".cyan
puts "Check the log file '#{log_file}' for a detailed story of our journey." if options[:log_enabled]
