#!/usr/bin/env ruby
require 'optparse'
require 'colorize'
require 'open3'
require 'timeout'
require 'terminal-table'

# Custom exception class for handling script errors
class SecurityAnalysisError < StandardError; end

# Handle Ctrl-C gracefully
trap("INT") do
  puts "\nProcess interrupted. Exiting...".red
  raise SecurityAnalysisError, "Process interrupted by user"
end

# Display script usage information
def display_help(opts)
  puts opts
  exit
end

# Menu information
def menu_info
  {
    title: "Security Analysis",
    description: "Checks for potential security vulnerabilities."
  }
end

# Validate if directory exists
def validate_directory(dir)
  unless Dir.exist?(dir)
    puts "Error: Directory '#{dir}' does not exist.".red
    raise SecurityAnalysisError, "Invalid directory: #{dir}"
  end
end

# Execute command with error handling
def execute_command(command, error_message, target_dir)
  begin
    stdout, stderr, status = Timeout.timeout(60) { Open3.capture3(command, chdir: target_dir) }
    unless status.success?
      puts error_message.red
      puts stderr.red unless stderr.empty?
      raise SecurityAnalysisError, "Command failed: #{command}"
    end
    stdout
  rescue Timeout::Error
    puts "Error: Command timed out.".red
    raise SecurityAnalysisError, "Command timed out: #{command}"
  end
end

# Check if gem is installed
def gem_installed?(gem_name)
  stdout, _stderr, _status = Open3.capture3("gem list #{gem_name} -i")
  stdout.strip == 'true'
end

# Check and prompt for gem installation if not present
def check_and_confirm_gem_installation(gem_name, target_dir)
  unless gem_installed?(gem_name)
    puts "#{gem_name} is not installed.".yellow
    puts "Installing #{gem_name} will modify your environment. Do you want to proceed? (y/n): "
    answer = STDIN.gets.strip.downcase
    if answer == 'y'
      puts "Installing #{gem_name}...".yellow
      execute_command("gem install #{gem_name}", "Failed to install #{gem_name}.", target_dir)
    else
      puts "Skipping installation of #{gem_name}. Some functionality may be limited.".red
      raise SecurityAnalysisError, "#{gem_name} not installed by user request"
    end
  end
end

# Perform security checks based on project type
def perform_security_checks(target_dir, ignore_patterns)
  results = []
  total_files = find_files(target_dir).count

  if rails_project?(target_dir)
    puts "Detected Project Type: Rails Project".cyan.bold
    check_and_confirm_gem_installation('brakeman', target_dir)
    puts "Running Brakeman security analysis...".cyan
    output = execute_command("brakeman -q --format text -p #{target_dir}", "💔 Brakeman encountered issues.", target_dir)
    puts "\n--- Brakeman Report ---".yellow.bold
    puts output
    results << { tool: 'Brakeman', output: output, status: 'Completed' }
  else
    puts "Detected Project Type: Ruby Project".cyan.bold
    gemfile_path = File.join(target_dir, 'Gemfile')
    if File.exist?(gemfile_path)
      check_and_confirm_gem_installation('bundler-audit', target_dir)
      puts "Running bundle install to ensure environment is set up...".cyan
      execute_command("bundle install", "💔 Bundle install failed.", target_dir)

      # Run bundler-audit in a more robust way
      begin
        audit_output = run_bundler_audit(target_dir)
        results << { tool: 'Bundler Audit', output: audit_output, status: audit_output.include?("No vulnerabilities found") ? 'Completed - No Issues' : 'Completed - Issues Found' }
      rescue SecurityAnalysisError
        results << { tool: 'Bundler Audit', output: '', status: 'Failed - Audit Not Completed' }
      end
    else
      puts "No Gemfile found in the target directory. Attempting to check dependencies via gemfile.lock...".yellow
      results << { tool: 'Bundler Audit', output: '', status: 'Skipped - No Gemfile' }
      # Implement alternative logic to check dependencies
    end

    check_for_hardcoded_secrets(target_dir, ignore_patterns, results)
  end

  add_code_owners(target_dir, results)
  display_summary(results, target_dir, total_files)
end

# Run bundler audit with separate update and check steps
def run_bundler_audit(target_dir)
  # Update advisory database
  begin
    puts "Updating ruby-advisory-db...".cyan
    execute_command("bundle audit update", "💔 bundler-audit failed to update advisory database.", target_dir)
  rescue SecurityAnalysisError => e
    puts "Skipping vulnerability check due to update failure.".red
    raise e
  end

  # Check for vulnerabilities
  begin
    puts "Running bundler-audit for security vulnerabilities...".cyan
    output = execute_command("bundle audit check", "💔 bundler-audit encountered issues during vulnerability check.", target_dir)
    puts "\n--- Bundler Audit Report ---".yellow.bold
    puts output
    return output
  rescue SecurityAnalysisError => e
    puts "Bundler audit check failed.".red
    raise e
  end
end

# Display a summary of results
def display_summary(results, target_dir, total_files)
  puts "\n=== Security Analysis Summary for Directory: #{target_dir} ===".green.bold
  puts "Total Files Scanned: #{total_files}".green
  rows = results.map do |result|
    [result[:tool], result[:status], result[:output].lines.count { |line| line.match(/warning|error|vulnerable|potential/i) }]
  end

  table = Terminal::Table.new :headings => ['Tool', 'Status', 'Issues Detected'], :rows => rows
  puts table
  puts "\nNext Steps:".blue.bold
  results.each do |result|
    if result[:status].include?('Issues Found') || result[:output].lines.any? { |line| line.match(/warning|error|vulnerable|potential/i) }
      puts "- For #{result[:tool]}: Review identified issues and engage the appropriate team to resolve them.".cyan
    end
  end
  puts "- Schedule follow-up reviews to ensure that the issues are resolved.".cyan
end

# Detect if the project is a Rails project
def rails_project?(dir)
  gemfile_path = File.join(dir, 'Gemfile')
  if File.exist?(gemfile_path)
    File.readlines(gemfile_path).any? { |line| line.include?("gem 'rails'") || line.include?('gem "rails"') }
  else
    %w[config/application.rb app/controllers/application_controller.rb config/routes.rb].all? { |file| File.exist?(File.join(dir, file)) }
  end
end

# Check for hardcoded secrets in Ruby files
def check_for_hardcoded_secrets(target_dir, ignore_patterns, results)
  secret_patterns = [
    /password\s*=\s*['"][^'"]+['"]/,
    /api_key\s*=\s*['"][^'"]+['"]/,
    /secret_key\s*=\s*['"][^'"]+['"]/,
    /access_token\s*=\s*['"][^'"]+['"]/,
    /client_secret\s*=\s*['"][^'"]+['"]/,
    /private_key\s*=\s*['"][^'"]+['"]/,
    /credential\s*=\s*['"][^'"]+['"]/
  ]
  issues_detected = []

  find_files(target_dir).each do |file|
    next if ignore_patterns.any? { |pattern| File.fnmatch(pattern, file) }

    File.foreach(file).with_index do |line, index|
      secret_patterns.each do |pattern|
        if line.match?(pattern)
          owner = find_owner(file, parse_codeowners(File.join(target_dir, 'CODEOWNERS')))
          issues_detected << "Potential hardcoded secret in #{file}:#{index + 1} (CODEOWNER: #{owner})"
          puts "⚠️ Potential hardcoded secret in #{file}:#{index + 1} (CODEOWNER: #{owner})".red
        end
      end
    end
  end

  results << { tool: 'Hardcoded Secrets Check', output: issues_detected.join("\n"), status: issues_detected.empty? ? 'Completed - No Issues' : 'Completed - Issues Found' }
end

# Find files with specific extensions
def find_files(target_dir)
  Dir.glob(File.join(target_dir, '**/*.{rb,erb,rake}'), File::FNM_CASEFOLD)
end

# Add code owner information to the results
def add_code_owners(target_dir, results)
  codeowners_path = File.join(target_dir, 'CODEOWNERS')
  if File.exist?(codeowners_path)
    codeowners = parse_codeowners(codeowners_path)
    results.each do |result|
      owner = find_owner(result[:output], codeowners)
      result[:owner] = owner
    end
  else
    puts "Warning: No CODEOWNERS file found. Cannot assign issues to owners.".yellow
  end
end

# Parse CODEOWNERS file
def parse_codeowners(path)
  codeowners = {}
  File.readlines(path).each do |line|
    next if line.strip.start_with?('#') || line.strip.empty?
    pattern, *owners = line.split
    codeowners[pattern] = owners
  end
  codeowners
end

# Find owner for the issue output
def find_owner(file_path, codeowners)
  codeowners.each do |pattern, owners|
    return owners.join(', ') if File.fnmatch(pattern, file_path)
  end
  'Unassigned'
end

# Parse command line options
options = { ignore_patterns: [] }
OptionParser.new do |opts|
  opts.banner = "Usage: security_analysis.rb [options] [target_directory]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") { |dir| options[:directory] = dir }
  opts.on("-i", "--ignore PATTERN", "Add an ignore pattern") { |pattern| options[:ignore_patterns] << pattern }
  opts.on("-h", "--help", "Displays Help") { display_help(opts) }
end.parse!

# Handle directory argument more defensively
if ARGV[0] && options[:directory].nil?
  options[:directory] = ARGV[0]
end

# Set target directory and validate it
target_dir = options[:directory] || Dir.pwd
validate_directory(target_dir)

begin
  perform_security_checks(target_dir, options[:ignore_patterns])
rescue SecurityAnalysisError => e
  puts "Error: #{e.message}".red
  exit 1
end
