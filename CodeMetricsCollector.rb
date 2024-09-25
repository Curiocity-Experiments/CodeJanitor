#!/usr/bin/env ruby

# CodeMetricsCollector.rb
#
# This script analyzes Ruby code files and collects various metrics,
# providing insights into code complexity and maintainability.
# Output messages have the persona of a bored accountant.

require 'stringio'
require 'io/console'
require 'json'
require 'digest'
require 'thread'
require 'logger'
require 'optparse'
require 'set'
require 'benchmark'
require 'monitor'  # Added to use Monitor instead of Mutex

# Constants for default values
DEFAULT_THREAD_COUNT = 4
DEFAULT_MIN_LOC = 10
DEFAULT_MAX_OUTPUT_WIDTH = begin
  require 'tty-screen'
  TTY::Screen.width
rescue LoadError
  120
end
DEFAULT_OUTPUT_DIR = 'metrics_reports'
DEFAULT_LOG_LEVEL = Logger::INFO
DEFAULT_OUTPUT_FORMATS = [:json, :csv]
DEFAULT_THRESHOLD_CYCLOMATIC_COMPLEXITY = 10
DEFAULT_THRESHOLD_NESTING_DEPTH = 5
DEFAULT_THRESHOLD_PARAMETERS = 4

# Required Gems
REQUIRED_GEMS = [
  'parser/current',
  'tty-table',
  'tty-screen',
  'tty-cursor',
  'colorize',
  'unicode_plot',
  'tty-progressbar',
  'sys/proctable'
]

# Check for required gems and prompt user to install if missing
def check_required_gems
  missing_gems = []
  REQUIRED_GEMS.each do |gem_name|
    begin
      require gem_name
    rescue LoadError
      gem_base = gem_name.split('/').first
      missing_gems << gem_base
    end
  end

  unless missing_gems.empty?
    puts "Error: Missing required gems: #{missing_gems.join(', ')}"
    puts "Please install them by running: gem install #{missing_gems.join(' ')}"
    exit 1
  end
end

check_required_gems

include Sys

# CodeMetricsCollector analyzes Ruby code files and collects various metrics.
class CodeMetricsCollector
  attr_reader :options

  COLOR_SCHEME = {
    title: :white,
    heading: :yellow,
    text: :light_white,
    warning: :light_yellow,
    error: :red,
    success: :green,
    info: :cyan
  }.freeze

  def initialize(directory, options = {})
    @directory = directory
    @options = default_options.merge(options)
    @metrics = {}
    @logger = initialize_logger
    @mutex = Monitor.new  # Changed from Mutex.new to Monitor.new
    @line_counts = []
    @complexity_counts = []
    @comment_ratios = []
    @duplication_ratios = []
    @file_processing_times = {}
    @total_files = 0
    @analyzed_files = 0
    @processed_files = 0
    @max_complexity = 0
    @stop_requested = false
    @code_churn = {}
    @dependencies = {}
    @commit_data = []
    @commit_frequencies = {}
  end

  # Collect metrics from all Ruby files in the directory.
  def collect_metrics
    setup_signal_traps
    start_input_listener

    @logger.info("Starting analysis of directory: #{@directory}".colorize(COLOR_SCHEME[:info]))
    files = ruby_files
    @logger.info("Total files found: #{files.count}".colorize(COLOR_SCHEME[:info]))

    start_time = Time.now

    total_time = Benchmark.realtime do
      @total_files = files.size

      # Initialize display components
      cursor = TTY::Cursor
      screen_width = @options[:max_output_width]

      # Clear the screen and hide the cursor
      print cursor.clear_screen
      print cursor.hide

      # Print the commentary
      puts "Starting analysis of #{@total_files} files. Let's get this over with.".colorize(COLOR_SCHEME[:info])
      puts "Processing files... Try to stay awake.".colorize(COLOR_SCHEME[:info])

      if @options[:incremental]
        files = filter_changed_files(files)
        @logger.info("Incremental analysis enabled. #{files.size} files to analyze after filtering.".colorize(COLOR_SCHEME[:info]))
      end

      # Move cursor to position below the commentary
      print cursor.move_to(0, 4)

      process_files_in_parallel(files, start_time, screen_width)

      # Collect additional metrics after processing files
      collect_commit_data
      analyze_commit_frequencies
      collect_dependencies
      collect_code_churn
    end

    # Ensure the input thread is terminated
    @input_thread.kill if @input_thread&.alive?

    # Assign execution metrics after the Benchmark block
    @total_execution_time = total_time
    @files_per_second = (@analyzed_files / total_time).round(2) if total_time.positive?
    @average_time_per_file = (total_time / @analyzed_files).round(2) if @analyzed_files.positive?
    @peak_memory = get_peak_memory_usage

    # Add a debug statement to inspect @metrics
    @logger.debug("Metrics collected: #{@metrics}") if @logger.level <= Logger::DEBUG

    # Check if any files were analyzed
    if @metrics.empty?
      @logger.debug("No files were analyzed. Possible reasons:")
      @logger.debug("- All files were skipped due to `min_loc` threshold.")
      @logger.debug("- No Ruby files found in the specified directory.")
      @logger.debug("- Errors occurred during file processing.")
      puts "\nNo files were analyzed. Please check the following:".colorize(COLOR_SCHEME[:warning])
      puts "- Ensure the directory path is correct."
      puts "- Verify that files meet the minimum LOC requirement (`min_loc` is set appropriately)."
      puts "- Review exclusion patterns or ignored files."
      return @metrics
    end



    # Generate reports after metrics are set
    generate_reports

    @metrics
  end

  private

  # Default options for the collector.
  def default_options
    {
      metrics: %i[loc methods classes cyclomatic_complexity halstead maintainability nesting_depth parameters],
      thresholds: {
        cyclomatic_complexity: DEFAULT_THRESHOLD_CYCLOMATIC_COMPLEXITY,
        nesting_depth: DEFAULT_THRESHOLD_NESTING_DEPTH,
        parameters: DEFAULT_THRESHOLD_PARAMETERS
      },
      ignore_patterns: ['spec/**/*', 'test/**/*', 'vendor/**/*', 'node_modules/**/*'],
      exclude_paths: [],
      thread_count: DEFAULT_THREAD_COUNT,
      incremental: true,
      follow_symlinks: false,
      output_format: DEFAULT_OUTPUT_FORMATS,
      output_dir: DEFAULT_OUTPUT_DIR,
      log_level: DEFAULT_LOG_LEVEL,
      log_file: nil,
      output_to_console: true,
      output_file: nil,
      min_loc: DEFAULT_MIN_LOC,
      max_output_width: DEFAULT_MAX_OUTPUT_WIDTH
    }
  end

  # Initialize the logger with specified log level and format.
  def initialize_logger
    logger = Logger.new(@options[:log_file] || STDERR)
    logger.level = @options[:log_level]
    logger.formatter = proc { |severity, _datetime, _progname, msg| "#{msg}\n" }
    logger
  end

  # Encapsulate suppression of warnings to limit scope.
  def with_warnings_suppressed
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original_stderr
  end

  # Set up signal traps for graceful termination.
  def setup_signal_traps
    Signal.trap("INT") do
      @stop_requested = true
      @logger.info("\nInterrupt received. Stopping analysis...".colorize(COLOR_SCHEME[:error]))
    end
  end

  # Start a thread to listen for the Esc key to terminate analysis.
  def start_input_listener
    @input_thread = Thread.new do
      while !@stop_requested
        begin
          if IO.select([STDIN], nil, nil, 0.1)
            char = STDIN.getch
            if char == "\e" # Esc key
              @stop_requested = true
              @logger.info("\nEsc key pressed. Stopping analysis...".colorize(COLOR_SCHEME[:error]))
              break
            end
          end
        rescue StandardError => e
          @logger.error("Input thread error: #{e.class} - #{e.message}".colorize(COLOR_SCHEME[:error]))
          break
        end
      end
    end
  end

  # Get a list of all Ruby files in the directory, excluding ignored patterns and paths.
  def ruby_files
    glob_pattern = File.join(@directory, '**', '*.rb')
    glob_options = @options[:follow_symlinks] ? File::FNM_DOTMATCH : File::FNM_NOESCAPE

    files = Dir.glob(glob_pattern, glob_options)
    @logger.debug("Found #{files.count} Ruby files before filtering") if @logger.level <= Logger::DEBUG

    files.reject { |file| ignored_file?(file) }
  rescue Errno::EACCES => e
    @logger.error("Permission denied: #{e.message}".colorize(COLOR_SCHEME[:error]))
    []
  end

  # Check if a file should be ignored based on patterns and paths.
  def ignored_file?(file)
    relative_path = file.sub("#{@directory}/", '')
    @options[:ignore_patterns].any? do |pattern|
      File.fnmatch(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
    end || @options[:exclude_paths].any? do |path|
      relative_path.start_with?(path)
    end
  end

  # Filter files to only include those changed since the last commit.
  def filter_changed_files(files)
    changed_files = git_changed_files
    files.select { |file| changed_files.include?(file) }
  end

  # Get a list of files changed since the last commit using Git.
  def git_changed_files
    Dir.chdir(@directory) do
      `git diff --name-only HEAD`.split("\n").map { |f| File.join(@directory, f) }
    end
  rescue StandardError
    @logger.warn('Git not available or not a git repository. Analyzing all files.'.colorize(COLOR_SCHEME[:warning]))
    ruby_files
  end

  # Process files in parallel using a thread pool and update display.
  def process_files_in_parallel(files, start_time, screen_width)
    queue = Queue.new
    files.each { |file| queue << file }

    thread_count = [@options[:thread_count], files.size].min
    threads = Array.new(thread_count) do
      Thread.new do
        until queue.empty? || @stop_requested
          file = nil
          @mutex.synchronize { file = queue.pop(true) rescue nil }
          break if @stop_requested || file.nil?

          @logger.debug("Processing file: #{file}") if @logger.level <= Logger::DEBUG
          collect_file_metrics(file)
          @mutex.synchronize do
            @analyzed_files += 1
            current_file = file
            processed_files = @analyzed_files
            # Move synchronization here to avoid recursive locking
            update_display(@total_files, processed_files, current_file, start_time, screen_width)
          end
        end
      end
    end

    threads.each(&:join)
  end

  # Collect metrics from a single Ruby file.
  def collect_file_metrics(file)
    start_time = Time.now
    content = File.read(file)
    loc = content.lines.count

    if loc < @options[:min_loc]
      @logger.debug("Skipping #{file} due to low LOC (#{loc})") if @logger.level <= Logger::DEBUG
      @mutex.synchronize { @line_counts << loc }
      return
    end

    buffer = Parser::Source::Buffer.new(file)
    buffer.source = content
    parser = Parser::CurrentRuby.new

    ast = nil
    with_warnings_suppressed { ast = parser.parse(buffer) }

    file_metrics = {
      loc: loc,
      methods: [],
      classes: 0,
      issues: [],
      comments: count_comments(content)
    }

    if ast
      visitor = MetricsVisitor.new(file_metrics, @options)
      visitor.process(ast)
    end

    # Calculate file-level metrics
    file_metrics[:maintainability_index] = calculate_file_maintainability_index(file_metrics)
    file_metrics[:comment_density] = calculate_comment_density(file_metrics)
    file_metrics[:duplication] = calculate_code_duplication(content)

    @mutex.synchronize do
      @metrics[file] = file_metrics
      @line_counts << loc
      @comment_ratios << file_metrics[:comment_density] if file_metrics[:comment_density]
      @duplication_ratios << file_metrics[:duplication] if file_metrics[:duplication]
      if file_metrics[:methods]
        file_metrics[:methods].each do |method|
          @complexity_counts << method[:cyclomatic_complexity]
        end
      end

      # Update max complexity
      if file_metrics[:methods]
        file_max_complexity = file_metrics[:methods].map { |m| m[:cyclomatic_complexity] }.max || 0
        if file_max_complexity > @max_complexity
          @max_complexity = file_max_complexity
          @max_complexity_file = file
          @logger.info("New max cyclomatic complexity: #{@max_complexity} in #{file}".colorize(COLOR_SCHEME[:warning]))
        end
      end

      processing_time = Time.now - start_time
      @file_processing_times[file] = processing_time
    end
  rescue Parser::SyntaxError => e
    @logger.error("Syntax error in #{file}: #{e.message}".colorize(COLOR_SCHEME[:error]))
    @mutex.synchronize do
      @metrics[file] ||= {}
      @metrics[file][:issues] ||= []
      @metrics[file][:issues] << "Syntax error: #{e.message}"
    end
  rescue Errno::EACCES => e
    @logger.error("Permission denied for #{file}: #{e.message}".colorize(COLOR_SCHEME[:error]))
    @mutex.synchronize do
      @metrics[file] ||= {}
      @metrics[file][:issues] ||= []
      @metrics[file][:issues] << "Permission error: #{e.message}"
    end
  rescue StandardError => e
    @logger.error("Error processing file #{file}: #{e.message}".colorize(COLOR_SCHEME[:error]))
    @logger.debug(e.backtrace.join("\n")) if @logger.level <= Logger::DEBUG
    @mutex.synchronize do
      @metrics[file] ||= {}
      @metrics[file][:issues] ||= []
      @metrics[file][:issues] << "Processing error: #{e.message}"
    end
  end

  # Count comment lines in the content
  def count_comments(content)
    content.lines.count { |line| line.strip.start_with?('#') }
  end

  # Calculate comment density for a file
  def calculate_comment_density(data)
    comment_lines = data[:comments]
    loc = data[:loc]
    return 0 if loc.zero?

    ((comment_lines.to_f / loc) * 100).round(2)
  end

  # Calculate code duplication percentage
  def calculate_code_duplication(content)
    lines = content.lines.map(&:strip).reject(&:empty?)
    total_lines = lines.size
    unique_lines = lines.uniq.size
    duplicated_lines = total_lines - unique_lines
    return 0 if total_lines.zero?

    ((duplicated_lines.to_f / total_lines) * 100).round(2)
  end

  # Calculate maintainability index for the entire file.
  def calculate_file_maintainability_index(data)
    total_volume = data[:methods].sum { |m| m[:halstead][:volume] || 0 }
    total_cyclomatic_complexity = data[:methods].sum { |m| m[:cyclomatic_complexity] || 0 }
    loc = data[:loc] || 0

    mi = 171 - 5.2 * Math.log(volume_nonzero(total_volume)) - 0.23 * total_cyclomatic_complexity - 16.2 * Math.log(loc_nonzero(loc))
    mi = [[mi, 0].max, 100].min
    mi.round(2)
  end

  # Handle zero values in logarithms.
  def volume_nonzero(volume)
    volume > 0 ? volume : 1
  end

  def loc_nonzero(loc)
    loc > 0 ? loc : 1
  end

  # Collect commit data using Git
  def collect_commit_data
    Dir.chdir(@directory) do
      @commit_data = `git log --pretty=format:'%H,%ct'`.split("\n").map do |line|
        hash, timestamp = line.split(',')
        { hash: hash, date: Time.at(timestamp.to_i) }
      end
    end
  rescue StandardError
    @logger.warn('Git not available or not a git repository. Skipping commit frequency metrics.'.colorize(COLOR_SCHEME[:warning]))
    @commit_data = []
  end

  # Analyze commit frequencies and populate @commit_frequencies
  def analyze_commit_frequencies
    return if @commit_data.empty?

    current_time = Time.now
    current_year = current_time.year
    current_month = current_time.month
    thirty_days_ago = current_time - (30 * 24 * 60 * 60)

    @commit_frequencies = {
      prior_years: 0,
      prior_months: 0,
      last_30_days: 0
    }

    @commit_data.each do |commit|
      date = commit[:date]
      if date.year < current_year
        @commit_frequencies[:prior_years] += 1
      elsif date.year == current_year && date.month < current_month
        @commit_frequencies[:prior_months] += 1
      elsif date >= thirty_days_ago
        @commit_frequencies[:last_30_days] += 1
      end
    end

    @logger.debug("Commit frequencies - #{@commit_frequencies}") if @logger.level <= Logger::DEBUG
  end

  # Collect dependencies from all files
  def collect_dependencies
    @dependencies = Hash.new { |hash, key| hash[key] = Set.new }

    @metrics.each do |file, _data|
      begin
        content = File.read(file)
        requires = content.scan(/require ['"]([^'"]+)['"]/).flatten
        requires.each { |req| @dependencies[req] << file }
      rescue StandardError => e
        @logger.error("Error reading file #{file} for dependency analysis: #{e.message}".colorize(COLOR_SCHEME[:error]))
      end
    end
  end

  # Collect code churn metrics using Git
  def collect_code_churn
    Dir.chdir(@directory) do
      @metrics.each_key do |file|
        relative_file = file.sub("#{@directory}/", '')
        commit_count = `git rev-list --count HEAD -- "#{relative_file}"`.to_i
        @code_churn[file] = commit_count
      end
    end
  rescue StandardError
    @logger.warn('Git not available or not a git repository. Skipping code churn metrics.'.colorize(COLOR_SCHEME[:warning]))
  end

  # Generate reports in specified formats.
  def generate_reports
    if @options[:output_file]
      Dir.mkdir(@options[:output_dir]) unless Dir.exist?(@options[:output_dir])

      if @options[:output_format].include?(:json)
        json_report_path = File.join(@options[:output_dir], "#{@options[:output_file]}.json")
        File.write(json_report_path, JSON.pretty_generate(@metrics))
        @logger.info("JSON report generated at #{json_report_path}".colorize(COLOR_SCHEME[:success]))
      end

      if @options[:output_format].include?(:csv)
        csv_report_path = File.join(@options[:output_dir], "#{@options[:output_file]}.csv")
        generate_csv_report(csv_report_path)
        @logger.info("CSV report generated at #{csv_report_path}".colorize(COLOR_SCHEME[:success]))
      end
    else
      @logger.info("No output file specified. Skipping report generation.".colorize(COLOR_SCHEME[:info]))
    end

    if @options[:output_to_console]
      output_metrics_to_console
    end
  end

  # Generate a CSV report.
  def generate_csv_report(file_path)
    require 'csv'
    CSV.open(file_path, 'w') do |csv|
      headers = %w[File LOC Classes Methods AvgCyclomaticComplexity MaintainabilityIndex CommentDensity Duplication Issues]
      csv << headers

      @metrics.each do |file, data|
        csv << [
          file,
          data[:loc],
          data[:classes],
          data[:methods].size,
          average_cyclomatic_complexity_for_file(data),
          data[:maintainability_index],
          data[:comment_density],
          data[:duplication],
          data[:issues].join('; ')
        ]
      end
    end
  end

  # Output metrics to the console in a condensed, tabular format.
  def output_metrics_to_console
    require 'tty-table'

    # Limit output to top 10 files with highest cyclomatic complexity
    top_files = @metrics.sort_by do |_file, data|
      -average_cyclomatic_complexity_for_file(data)
    end.first(10)

    if top_files.empty?
      puts "\nNo files were analyzed to display in the Top 10 Files by Cyclomatic Complexity.".colorize(COLOR_SCHEME[:warning])
    else
      rows = top_files.map do |file, data|
        [
          truncate(file, 80),
          data[:loc],
          data[:classes],
          data[:methods].size,
          average_cyclomatic_complexity_for_file(data),
          data[:maintainability_index],
          @code_churn[file] || 0,
          data[:issues].size
        ]
      end

      table = TTY::Table.new(
        header: [
          'File'.colorize(COLOR_SCHEME[:heading]),
          'LOC'.colorize(COLOR_SCHEME[:heading]),
          'Cls'.colorize(COLOR_SCHEME[:heading]),
          'Mth'.colorize(COLOR_SCHEME[:heading]),
          'Avg Cmplx'.colorize(COLOR_SCHEME[:heading]),
          'MI'.colorize(COLOR_SCHEME[:heading]),
          'Churn'.colorize(COLOR_SCHEME[:heading]),
          'Issues'.colorize(COLOR_SCHEME[:heading])
        ],
        rows: rows
      )

      puts "\nTop 10 Files by Cyclomatic Complexity:".colorize(COLOR_SCHEME[:title])
      puts "(High complexity methods can be difficult to maintain. Consider refactoring these methods to simplify them.)".colorize(COLOR_SCHEME[:warning])

      # Render the table
      puts table.render(:unicode) do |renderer|
        renderer.alignments = [:left, :center, :center, :center, :center, :center, :center, :center]
        renderer.width = @options[:max_output_width]
      end
    end

    # Collect all issues across all files
    all_issues = []
    @metrics.each do |file, data|
      data[:issues].each do |issue|
        all_issues << {
          file: file,
          issue: issue,
          complexity: average_cyclomatic_complexity_for_file(data),
          maintainability_index: data[:maintainability_index],
          loc: data[:loc]
        }
      end
    end

    # Sort issues by cyclomatic complexity (descending)
    top_issues = all_issues.sort_by { |issue| -issue[:complexity] }.first(5)

    # Present top 5 issues in a single table
    if top_issues.any?
      rows = top_issues.map do |issue|
        [
          truncate(issue[:file], 50),
          truncate(issue[:issue], 60),
          issue[:complexity],
          issue[:maintainability_index],
          issue[:loc]
        ]
      end

      table = TTY::Table.new(
        header: [
          'File'.colorize(COLOR_SCHEME[:heading]),
          'Issue'.colorize(COLOR_SCHEME[:heading]),
          'Complexity'.colorize(COLOR_SCHEME[:heading]),
          'MI'.colorize(COLOR_SCHEME[:heading]),
          'LOC'.colorize(COLOR_SCHEME[:heading])
        ],
        rows: rows
      )

      puts "\nTop 5 Issues with Full Details:".colorize(COLOR_SCHEME[:title])

      puts table.render(:unicode) do |renderer|
        renderer.alignments = [:left, :left, :center, :center, :center]
        renderer.width = @options[:max_output_width]
      end
    else
      puts "\nNo issues detected.".colorize(COLOR_SCHEME[:success])
    end

    # Output charts
    puts "\n" + '=' * @options[:max_output_width]
    puts "Charts".center(@options[:max_output_width]).colorize(COLOR_SCHEME[:title])
    puts '=' * @options[:max_output_width]

    # Generate chart strings
    loc_chart = loc_distribution_chart
    complexity_chart = cyclomatic_complexity_distribution_chart
    comment_chart = comment_density_distribution_chart
    duplication_chart = code_duplication_distribution_chart

    # Output charts with headings and explanations
    if @line_counts.any?
      puts "\nLOC Distribution per File:".colorize(COLOR_SCHEME[:title])
      puts "This chart shows the distribution of lines of code across files. Large files may need refactoring.".colorize(COLOR_SCHEME[:info])
      puts loc_chart
    else
      puts "\nNo data available for LOC Distribution chart.".colorize(COLOR_SCHEME[:warning])
    end

    if @complexity_counts.any?
      puts "\nCyclomatic Complexity Distribution:".colorize(COLOR_SCHEME[:title])
      puts "This chart displays the complexity of methods. High complexity may indicate methods that are difficult to maintain.".colorize(COLOR_SCHEME[:info])
      puts complexity_chart
    else
      puts "\nNo data available for Cyclomatic Complexity Distribution chart.".colorize(COLOR_SCHEME[:warning])
    end

    if @comment_ratios.any?
      puts "\nComment Density Across Files (%):".colorize(COLOR_SCHEME[:title])
      puts "A low comment density might suggest insufficient documentation.".colorize(COLOR_SCHEME[:info])
      puts comment_chart
    else
      puts "\nNo data available for Comment Density chart.".colorize(COLOR_SCHEME[:warning])
    end

    if @duplication_ratios.any?
      puts "\nCode Duplication in Files (%):".colorize(COLOR_SCHEME[:title])
      puts "This chart shows the percentage of duplicated lines in files. High duplication suggests code that could be refactored to improve maintainability.".colorize(COLOR_SCHEME[:info])
      puts "Duplication is calculated by comparing the number of unique lines to the total number of lines in a file.".colorize(COLOR_SCHEME[:info])
      puts duplication_chart
    else
      puts "\nNo data available for Code Duplication chart.".colorize(COLOR_SCHEME[:warning])
    end

    # Commit Frequency Metrics
    puts "\nCommit Frequency Metrics:".colorize(COLOR_SCHEME[:title])
    puts "This table shows the number of commits over different periods. It helps identify active development phases and potentially neglected code.".colorize(COLOR_SCHEME[:info])
    puts "Consider reviewing areas with low recent activity for possible updates or deprecation.".colorize(COLOR_SCHEME[:info])
    puts output_commit_frequencies

    # Dependency Analysis
    if @dependencies.any?
      puts "\nDependency Analysis:".colorize(COLOR_SCHEME[:title])
      puts "This table lists the dependencies used in your project and how many times they are required.".colorize(COLOR_SCHEME[:info])
      puts "High usage dependencies are critical to your project. Ensure they are up-to-date and secure.".colorize(COLOR_SCHEME[:info])
      puts output_dependency_analysis
    else
      puts "\nNo dependencies found or unable to parse requires.".colorize(COLOR_SCHEME[:warning])
    end

    # Report files with long processing times
    # report_slow_files

    # Final Summary Section
    puts "\n" + '=' * @options[:max_output_width]
    puts "Analysis Complete".center(@options[:max_output_width]).colorize(COLOR_SCHEME[:success])
    puts '=' * @options[:max_output_width]

    # Key Insights Table
    puts "\nKey Insights:".colorize(COLOR_SCHEME[:heading])

    insights_table = TTY::Table.new(
      header: [
        'Metric'.colorize(COLOR_SCHEME[:heading]),
        'Value'.colorize(COLOR_SCHEME[:heading])
      ],
      rows: [
        ['Total Lines of Code (LOC)', @metrics.values.sum { |data| data[:loc] || 0 }],
        ['Total Classes', @metrics.values.sum { |data| data[:classes] || 0 }],
        ['Total Methods', @metrics.values.sum { |data| data[:methods].size || 0 }],
        ['Average Cyclomatic Complexity', average_cyclomatic_complexity],
        ['Files with High Complexity', high_complexity_files.count],
        ['Most Complex File', most_complex_file],
        ['Peak Memory Usage', "#{format('%.2f', @peak_memory)} MB"],
        ['Total Execution Time', "#{format('%.2f', @total_execution_time)} seconds"],
        ['Processing Speed', "#{format('%.2f', @files_per_second)} files/second"],
        ['Average Time per File', @average_time_per_file ? "#{format('%.2f', @average_time_per_file * 1000)} ms" : 'N/A'] # Converted to milliseconds
      ]
    )

    puts insights_table.render(:unicode) do |renderer|
      renderer.alignments = [:left, :right]
      renderer.width = @options[:max_output_width]
    end

    puts '=' * @options[:max_output_width] + "\n"
  end

  # Output commit frequencies in a table.
  def output_commit_frequencies
    return "No commit data available. Ensure you're running this in a Git repository.".colorize(COLOR_SCHEME[:warning]) if @commit_frequencies.empty?

    rows = [
      ['Prior Years', @commit_frequencies[:prior_years]],
      ['Prior Months This Year', @commit_frequencies[:prior_months]],
      ['Last 30 Days', @commit_frequencies[:last_30_days]]
    ]
    table = TTY::Table.new(
      header: ['Period'.colorize(COLOR_SCHEME[:heading]), 'Commit Count'.colorize(COLOR_SCHEME[:heading])],
      rows: rows
    )
    table.render(:unicode) do |renderer|
      renderer.alignments = [:left, :center]
      renderer.width = @options[:max_output_width]
    end
  end

  # Output dependency analysis in a table.
  def output_dependency_analysis
    return "No dependencies found or unable to parse requires.".colorize(COLOR_SCHEME[:warning]) if @dependencies.empty?

    sorted_dependencies = @dependencies.sort_by { |_dep, files| -files.size }.first(10)
    rows = sorted_dependencies.map do |dep, files|
      [dep, files.size]
    end
    table = TTY::Table.new(
      header: ['Dependency'.colorize(COLOR_SCHEME[:heading]), 'Usage Count'.colorize(COLOR_SCHEME[:heading])],
      rows: rows
    )
    table.render(:unicode) do |renderer|
      renderer.alignments = [:left, :center]
      renderer.width = @options[:max_output_width]
    end
  end

  # Report files with long processing times.
  def report_slow_files
    slow_files = @file_processing_times.sort_by { |_file, time| -time }.first(5)
    return unless slow_files.any?

    puts "\nFiles with Long Processing Time:".colorize(COLOR_SCHEME[:title])
    rows = slow_files.map do |file, time|
      [
        truncate(file, 40),
        format('%.2f', time)
      ]
    end

    table = TTY::Table.new(
      header: ['File'.colorize(COLOR_SCHEME[:heading]), 'Time (s)'.colorize(COLOR_SCHEME[:heading])],
      rows: rows
    )
    puts table.render(:unicode)
  end

  # Truncate a string to a maximum length.
  def truncate(string, max_length)
    string.length > max_length ? "#{string[0...max_length - 3]}..." : string
  end

  # Calculate average cyclomatic complexity across all files.
  def average_cyclomatic_complexity
    complexities = @metrics.values.flat_map { |data| data[:methods].map { |m| m[:cyclomatic_complexity] } }
    return 0 if complexities.empty?

    (complexities.sum.to_f / complexities.size).round(2)
  end

  # Calculate average cyclomatic complexity for a single file.
  def average_cyclomatic_complexity_for_file(data)
    complexities = data[:methods].map { |m| m[:cyclomatic_complexity] }
    return 0 if complexities.empty?

    (complexities.sum.to_f / complexities.size).round(2)
  end

  # Get files with high complexity based on threshold.
  def high_complexity_files
    threshold = @options[:thresholds][:cyclomatic_complexity] || DEFAULT_THRESHOLD_CYCLOMATIC_COMPLEXITY
    @metrics.select do |_file, data|
      data[:methods].any? { |m| m[:cyclomatic_complexity] > threshold }
    end
  end

  # Get the most complex file based on cyclomatic complexity.
  def most_complex_file
    @metrics.max_by do |_file, data|
      data[:methods].map { |m| m[:cyclomatic_complexity] }.max || 0
    end&.first || 'N/A'
  end

  # Get peak memory usage of the process.
  def get_peak_memory_usage
    begin
      # Retrieve the current process information
      proc_info = ProcTable.ps.find { |p| p.pid == Process.pid }

      if proc_info && proc_info.respond_to?(:rss)
        memory_usage = proc_info.rss

        # Determine the operating system
        os = RbConfig::CONFIG['host_os']

        memory_usage_mb = case os
                          when /linux|unix/
                            # On Linux and Unix-like systems, rss is in KB
                            (memory_usage / 1024.0).round(2)
                          when /darwin/
                            # On macOS, rss is in bytes
                            (memory_usage / (1024.0 * 1024.0)).round(2)
                          else
                            # Default assumption: rss is in KB
                            (memory_usage / 1024.0).round(2)
                          end

        @logger.debug("Retrieved memory usage - #{memory_usage_mb} MB") if @logger.level <= Logger::DEBUG
        return memory_usage_mb if memory_usage.positive?
      else
        @logger.warn('Unable to retrieve memory usage.'.colorize(COLOR_SCHEME[:warning])) if @logger.level <= Logger::WARN
      end

      0.0
    rescue StandardError => e
      @logger.error("Error retrieving memory usage: #{e.message}".colorize(COLOR_SCHEME[:error]))
      0.0
    end
  end


  # Create LOC distribution chart.
  def loc_distribution_chart
    return "No data available for LOC Distribution chart." if @line_counts.empty?

    bucket_size = 200
    histogram_data = Hash.new(0)
    @line_counts.each do |loc|
      bucket = ((loc.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }

    plot = UnicodePlot.barplot(
      sorted_data.map { |bucket, _| "#{bucket}-#{bucket + bucket_size - 1}" },
      sorted_data.map { |_, count| count },
      title: "LOC Distribution",
      xlabel: "LOC Range",
      ylabel: "Number of Files",
      width: [@options[:max_output_width] - 5, 50].min  # Adjusted width
    )

    output = StringIO.new
    plot.render(output)
    output.string
  end

  # Create cyclomatic complexity distribution chart.
  def cyclomatic_complexity_distribution_chart
    return "No data available for Cyclomatic Complexity Distribution chart." if @complexity_counts.empty?

    bucket_size = 2
    histogram_data = Hash.new(0)
    @complexity_counts.each do |complexity|
      bucket = ((complexity.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }

    plot = UnicodePlot.barplot(
      sorted_data.map { |bucket, _| "#{bucket}-#{bucket + bucket_size - 1}" },
      sorted_data.map { |_, count| count },
      title: "Cyclomatic Complexity Distribution",
      xlabel: "Complexity Range",
      ylabel: "Number of Methods",
      width: @options[:max_output_width] - 10
    )

    output = StringIO.new
    plot.render(output)
    output.string
  end

  # Create comment density distribution chart.
  def comment_density_distribution_chart
    return "No data available for Comment Density chart." if @comment_ratios.empty?

    bucket_size = 10
    histogram_data = Hash.new(0)
    @comment_ratios.each do |ratio|
      bucket = ((ratio.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }

    plot = UnicodePlot.barplot(
      sorted_data.map { |bucket, _| "#{bucket}%" },
      sorted_data.map { |_, count| count },
      title: "Comment Density",
      xlabel: "Density Range",
      ylabel: "Files",
      width: @options[:max_output_width] / 2 - 5
    )

    output = StringIO.new
    plot.render(output)
    output.string
  end

  # Create code duplication distribution chart.
  def code_duplication_distribution_chart
    return "No data available for Code Duplication chart." if @duplication_ratios.empty?

    bucket_size = 5
    histogram_data = Hash.new(0)
    @duplication_ratios.each do |ratio|
      bucket = ((ratio.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }

    plot = UnicodePlot.barplot(
      sorted_data.map { |bucket, _| "#{bucket}%" },
      sorted_data.map { |_, count| count },
      title: "Code Duplication",
      xlabel: "Duplication %",
      ylabel: "Files",
      width: @options[:max_output_width] / 2 - 5
    )

    output = StringIO.new
    plot.render(output)
    output.string
  end

  # Format duration from seconds to HH:MM:SS
  def format_duration(seconds)
    Time.at(seconds).utc.strftime("%H:%M:%S")
  rescue
    "00:00:00"
  end

  # Print a simple progress bar
  def print_progress_bar(percentage, screen_width)
    bar_width = screen_width - 30
    filled_length = (percentage / 100.0 * bar_width).round
    bar = "=" * filled_length + "-" * (bar_width - filled_length)
    puts "[#{bar}] #{percentage}%"
  end

  # Update the display with grouped metrics
  def update_display(total_files, processed_files, current_file, start_time, screen_width)
    cursor = TTY::Cursor

    percentage = (processed_files.to_f / total_files * 100).round(2)
    elapsed_time = Time.now - start_time
    eta = if processed_files > 0
            ((elapsed_time / processed_files) * (total_files - processed_files))
          else
            0
          end

    # Compute real-time metrics
    total_loc = @metrics.values.sum { |data| data[:loc] || 0 }
    total_classes = @metrics.values.sum { |data| data[:classes] || 0 }
    total_methods = @metrics.values.sum { |data| data[:methods].size || 0 }
    all_complexities = @metrics.values.flat_map { |data| data[:methods].map { |m| m[:cyclomatic_complexity] } }
    average_complexity = if all_complexities.any?
                           (all_complexities.sum.to_f / all_complexities.size).round(2)
                         else
                           0
                         end
    max_complexity = @max_complexity

    # Build the table with grouped metrics
    rows = [
      ['Progress Metrics', '', 'Code Metrics', ''],
      ['Total Files', total_files, 'Total LOC', total_loc],
      ['Files Processed', processed_files, 'Total Classes', total_classes],
      ['Completed', "#{percentage}%", 'Total Methods', total_methods],
      ['Elapsed Time', format_duration(elapsed_time), 'Avg Complexity', average_complexity],
      ['ETA', format_duration(eta), 'Max Complexity', max_complexity]
    ]

    table = TTY::Table.new(rows)
    table_renderer = table.render(:ascii, alignments: [:left, :right, :left, :right], padding: [0, 1, 0, 1], width: screen_width)

    @mutex.synchronize do
      # Move the cursor up to overwrite the previous table and file
      print cursor.move_to(0, 4)
      print cursor.clear_screen_down
      puts table_renderer
      puts "\nProcessing File: #{truncate(current_file, screen_width - 20)}"
      print_progress_bar(percentage, screen_width)
    end

    # Optional: Sleep briefly to reduce flickering
    sleep(0.05)
  end
end

# MetricsVisitor traverses the AST and collects metrics.
class MetricsVisitor < Parser::AST::Processor
  COMPLEXITY_NODES = %i[if while until for rescue when and or case].freeze

  def initialize(file_metrics, options)
    @file_metrics = file_metrics
    @options = options
  end

  # Process class definitions.
  def on_class(node)
    @file_metrics[:classes] += 1
    super
  end

  # Process method definitions.
  def on_def(node)
    method_name = node.children[0]
    params = node.children[1]
    body = node.children[2]

    method_metrics = analyze_method(method_name, params, body)
    @file_metrics[:methods] << method_metrics

    super
  end

  private

  # Analyze a method and collect metrics.
  def analyze_method(method_name, params, body)
    cyclomatic_complexity = calculate_cyclomatic_complexity(body)
    halstead_metrics = calculate_halstead_metrics(body)
    max_nesting_depth = calculate_max_nesting_depth(body)
    params_count = params.children.size
    loc = calculate_loc(body)
    maintainability_index = calculate_maintainability_index(cyclomatic_complexity, halstead_metrics[:volume], loc)

    detect_code_smells(method_name, cyclomatic_complexity, max_nesting_depth, params_count)

    {
      name: method_name,
      params_count: params_count,
      cyclomatic_complexity: cyclomatic_complexity,
      max_nesting_depth: max_nesting_depth,
      halstead: halstead_metrics,
      loc: loc,
      maintainability_index: maintainability_index
    }
  end

  # Calculate cyclomatic complexity.
  def calculate_cyclomatic_complexity(node)
    complexity = 1
    traverse_for_complexity(node, complexity)
  end

  def traverse_for_complexity(node, complexity)
    return complexity unless node.is_a?(Parser::AST::Node)

    if COMPLEXITY_NODES.include?(node.type) || logical_operator?(node)
      complexity += 1
    end

    node.children.each do |child|
      complexity = traverse_for_complexity(child, complexity) if child.is_a?(Parser::AST::Node)
    end

    complexity
  end

  def logical_operator?(node)
    node.type == :send && %i[&& ||].include?(node.children[1])
  end

  # Calculate Halstead metrics.
  def calculate_halstead_metrics(node, metrics = { operators: Set.new, operands: Set.new, operator_count: 0, operand_count: 0, volume: 0 })
    return metrics unless node.is_a?(Parser::AST::Node)

    if node.type == :send
      operator = node.children[1]
      metrics[:operators] << operator
      metrics[:operator_count] += 1

      operands = node.children[2..-1]
      operands.each do |operand|
        if operand.is_a?(Parser::AST::Node)
          calculate_halstead_metrics(operand, metrics)
        else
          metrics[:operands] << operand
          metrics[:operand_count] += 1 if operand
        end
      end
    else
      node.children.each do |child|
        calculate_halstead_metrics(child, metrics) if child.is_a?(Parser::AST::Node)
      end
    end

    n1 = metrics[:operators].size
    n2 = metrics[:operands].size
    n1_total = metrics[:operator_count]
    n2_total = metrics[:operand_count]
    vocabulary = n1 + n2
    length = n1_total + n2_total

    metrics[:volume] = vocabulary.positive? ? (length * Math.log2(vocabulary)) : 0

    metrics
  end

  # Calculate maximum nesting depth.
  def calculate_max_nesting_depth(node, depth = 0)
    return depth unless node.is_a?(Parser::AST::Node)

    if %i[if while until for begin rescue case].include?(node.type)
      depth += 1
    end

    max_depth = depth
    node.children.each do |child|
      child_depth = calculate_max_nesting_depth(child, depth) if child.is_a?(Parser::AST::Node)
      max_depth = [max_depth, child_depth].max if child_depth
    end

    max_depth
  end

  # Calculate lines of code for a method.
  def calculate_loc(node)
    return 0 unless node.is_a?(Parser::AST::Node)

    begin
      start_line = node.loc.expression.line
      end_line = node.loc.expression.last_line
      end_line - start_line + 1
    rescue
      0
    end
  end

  # Calculate maintainability index.
  def calculate_maintainability_index(cyclomatic_complexity, volume, loc)
    mi = 171 - 5.2 * Math.log(volume_nonzero(volume)) - 0.23 * cyclomatic_complexity - 16.2 * Math.log(loc_nonzero(loc))
    mi = [[mi, 0].max, 100].min
    mi.round(2)
  end

  # Handle zero values in logarithms.
  def volume_nonzero(volume)
    volume > 0 ? volume : 1
  end

  def loc_nonzero(loc)
    loc > 0 ? loc : 1
  end

  # Detect code smells and add issues to the file metrics.
  def detect_code_smells(method_name, cyclomatic_complexity, max_nesting_depth, params_count)
    if cyclomatic_complexity > (@options[:thresholds][:cyclomatic_complexity] || DEFAULT_THRESHOLD_CYCLOMATIC_COMPLEXITY)
      @file_metrics[:issues] << "High complexity in '#{method_name}' (#{cyclomatic_complexity})."
    end

    if max_nesting_depth > (@options[:thresholds][:nesting_depth] || DEFAULT_THRESHOLD_NESTING_DEPTH)
      @file_metrics[:issues] << "Deep nesting in '#{method_name}' (#{max_nesting_depth} levels)."
    end

    if params_count > (@options[:thresholds][:parameters] || DEFAULT_THRESHOLD_PARAMETERS)
      @file_metrics[:issues] << "Too many parameters in '#{method_name}' (#{params_count})."
    end
  end
end

# Parse command-line options and run the collector
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ./CodeMetricsCollector.rb -d DIRECTORY [options]"

  opts.on("-d", "--directory PATH", "Directory to analyze") do |d|
    options[:directory] = d
  end

  opts.on("-o", "--output-dir DIR", "Directory to save reports (default: #{DEFAULT_OUTPUT_DIR})") do |o|
    options[:output_dir] = o
  end

  opts.on("--output-file FILE", "File to save metrics report (without extension)") do |f|
    options[:output_file] = f
  end

  opts.on("-f", "--format FORMAT", "Output format (json,csv) (default: json,csv)") do |f|
    options[:output_format] = f.split(',').map(&:to_sym)
  end

  opts.on("-t", "--threads COUNT", Integer, "Number of threads (default: #{DEFAULT_THREAD_COUNT})") do |t|
    options[:thread_count] = t
  end

  opts.on("-l", "--log-level LEVEL", "Log level (DEBUG, INFO, WARN, ERROR) (default: INFO)") do |l|
    begin
      options[:log_level] = Logger.const_get(l.upcase)
    rescue NameError
      puts "Invalid log level: #{l}. Using default: INFO."
      options[:log_level] = DEFAULT_LOG_LEVEL
    end
  end

  opts.on("--no-incremental", "Disable incremental analysis") do
    options[:incremental] = false
  end

  opts.on("--ignore PATTERN", "Ignore files matching pattern") do |pattern|
    options[:ignore_patterns] ||= []
    options[:ignore_patterns] << pattern
  end

  opts.on("--exclude PATH", "Exclude directory from analysis") do |path|
    options[:exclude_paths] ||= []
    options[:exclude_paths] << path
  end

  opts.on("--threshold METRIC=VALUE", "Set threshold for a metric (e.g., --threshold cyclomatic_complexity=15)") do |threshold|
    key, value = threshold.split('=')
    options[:thresholds] ||= {}
    options[:thresholds][key.to_sym] = value.to_i if key && value
  end

  opts.on("--no-console-output", "Disable output to console") do
    options[:output_to_console] = false
  end

  opts.on("--min-loc VALUE", Integer, "Minimum LOC to analyze a file (default: #{DEFAULT_MIN_LOC})") do |value|
    options[:min_loc] = value
  end

  opts.on("--max-output-width VALUE", Integer, "Maximum output width for terminal (default: auto-detect)") do |value|
    options[:max_output_width] = value
  end

  opts.on("-v", "--verbose", "Run verbosely (set log level to DEBUG)") do
    options[:log_level] = Logger::DEBUG
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

# Validate required options.
if options[:directory].nil?
  puts "Error: Directory is required."
  puts "Usage: ./CodeMetricsCollector.rb -d /path/to/your/project [options]"
  exit 1
end

# Run the collector.
collector = CodeMetricsCollector.new(options[:directory], options)
collector.collect_metrics
