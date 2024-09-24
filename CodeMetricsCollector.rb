#!/usr/bin/env ruby

# code_metrics_collector.rb

# This script analyzes Ruby code files and collects various metrics,
# providing insights into code complexity and maintainability.
# Output messages have the persona of a bored accountant.

require 'stringio'
require 'io/console'

# Temporarily suppress warnings during require
old_stderr = $stderr
$stderr = StringIO.new

require 'parser/current'

$stderr = old_stderr

require 'json'
require 'digest'
require 'thread'
require 'logger'
require 'optparse'
require 'set'
require 'benchmark'

# Install missing gems if necessary
begin
  require 'tty-table'
  require 'tty-screen'
  require 'tty-cursor'
  require 'colorize'
  require 'unicode_plot'
  require 'terminal-table'
rescue LoadError => e
  # Extract the missing gem name from the error message
  missing_gem = e.message.match(/-- (.+)$/)[1]
  puts "Missing gem detected: #{missing_gem}"
  puts "Installing required gem '#{missing_gem}'..."
  system("gem install #{missing_gem}")
  Gem.clear_paths
  retry
end

# CodeMetricsCollector analyzes Ruby code files and collects various metrics.
class CodeMetricsCollector
  attr_reader :options

  # Initialize with the directory to analyze and options.
  def initialize(directory, options = {})
    @directory = directory
    @options = default_options.merge(options)
    @metrics = {}
    @logger = Logger.new(@options[:log_file] || STDOUT)
    @logger.level = @options[:log_level]
    @logger.formatter = proc do |_severity, _datetime, _progname, msg|
      "#{msg}\n"
    end
    @mutex = Mutex.new
    @line_counts = []           # For storing LOC per file
    @complexity_counts = []     # For cyclomatic complexity distribution
    @comment_ratios = []        # For comment density data
    @duplication_ratios = []    # For code duplication data
    @file_processing_times = {} # For per-file processing time
    @total_files = 0
    @analyzed_files = 0
    @max_complexity = 0         # For tracking max cyclomatic complexity
    @stop_requested = false     # For handling interrupt signal
  end

  # Collect metrics from all Ruby files in the directory.
  def collect_metrics
    # Trap SIGINT (Ctrl+C)
    Signal.trap("INT") do
      @stop_requested = true
      @logger.info("\nInterrupt received. Stopping analysis...".colorize(:red))
    end

    # Start input listener thread for Esc key
    input_thread = Thread.new do
      while !@stop_requested
        begin
          if IO.select([STDIN], nil, nil, 0.1)
            char = STDIN.getch
            if char == "\e" # Esc key
              @stop_requested = true
              @logger.info("\nEsc key pressed. Stopping analysis...".colorize(:red))
              break
            end
          end
        rescue Exception => e
          @logger.error("Input thread error: #{e.message}")
          break
        end
      end
    end

    total_time = Benchmark.realtime do
      files = ruby_files
      @total_files = files.size

      # Initialize display components
      cursor = TTY::Cursor
      screen_width = TTY::Screen.width

      # Clear the screen and hide the cursor
      print cursor.clear_screen
      print cursor.hide

      # Print the commentary
      puts "Starting analysis of #{@total_files} files. Let's get this over with.".colorize(:light_blue)
      puts "Processing files... Try to stay awake.".colorize(:light_blue)

      if @options[:incremental]
        files = filter_changed_files(files)
        @logger.info("Incremental analysis enabled. #{files.size} files to analyze after filtering.".colorize(:light_blue))
      end

      # Move cursor to position below the commentary
      print cursor.move_to(0, 4)

      process_files_in_parallel(files)

      generate_reports
      @logger.info("Analysis complete. What a thrill.".colorize(:light_blue))
    end

    # Ensure the input thread is terminated
    input_thread.kill if input_thread.alive?

    # Log total execution time and files analyzed
    files_per_second = (@analyzed_files / total_time).round(2) rescue 0
    average_time_per_file = (total_time / @analyzed_files).round(2) rescue 0
    peak_memory = get_peak_memory_usage
    @logger.info("Total execution time: #{format('%.2f', total_time)} seconds. Could've been worse.".colorize(:light_blue))
    @logger.info("Peak memory usage: #{format('%.2f', peak_memory)} MB. Could be better.".colorize(:light_blue))
    @logger.info("Processing speed: #{files_per_second} files/second.".colorize(:light_blue))
    @logger.info("Average time per file: #{average_time_per_file} seconds.".colorize(:light_blue))
    @logger.info("Total files analyzed: #{@analyzed_files} out of #{@total_files}. How exciting.".colorize(:light_blue))

    report_slow_files

    @metrics
  end

  private

  # Default options for the collector.
  def default_options
    {
      metrics: %i[loc methods classes cyclomatic_complexity halstead maintainability nesting_depth parameters],
      thresholds: {},
      ignore_patterns: ['spec/**/*', 'test/**/*', 'vendor/**/*', 'node_modules/**/*', '.*'],  # Default ignore patterns
      exclude_paths: [],
      thread_count: 4,
      incremental: true,
      output_format: %i[json csv],
      output_dir: 'metrics_reports',
      log_level: Logger::INFO,
      log_file: nil,
      output_to_console: true,      # Option to output metrics to console
      output_file: nil,             # Option to specify a file to save metrics
      min_loc: 100,                 # Minimum lines of code to analyze a file
      max_output_width: 160         # Maximum output width for terminal
    }
  end

  # Get a list of all Ruby files in the directory, excluding ignored patterns and paths.
  def ruby_files
    Dir.glob(File.join(@directory, '**', '*.rb')).reject do |file|
      ignored_file?(file)
    end
  end

  # Check if a file should be ignored based on patterns and paths.
  def ignored_file?(file)
    relative_path = file.sub("#{@directory}/", '')
    @options[:ignore_patterns].any? { |pattern| File.fnmatch(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) } ||
      @options[:exclude_paths].any? { |path| relative_path.start_with?(path) }
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
  rescue
    @logger.warn('Git not available or not a git repository. Analyzing all files.')
    ruby_files
  end

  # Process files in parallel using a thread pool.
  def process_files_in_parallel(files)
    queue = Queue.new
    files.each { |file| queue << file }

    thread_count = [@options[:thread_count], files.size].min

    total_files = files.size
    @processed_files = 0

    # Start the worker threads
    threads = Array.new(thread_count) do
      Thread.new do
        until queue.empty? || @stop_requested
          file = queue.pop(true) rescue nil
          break if @stop_requested
          if file
            collect_file_metrics(file)
            @mutex.synchronize do
              @analyzed_files += 1
              @processed_files += 1
            end
            update_display(total_files, @processed_files, file, Time.now)
          end
        end
      end
    end

    threads.each(&:join)

    # Ensure the cursor is visible again
    print TTY::Cursor.show
  end

  def update_display(total_files, processed_files, current_file, start_time)
    cursor = TTY::Cursor
    screen_width = TTY::Screen.width

    percentage = (processed_files.to_f / total_files * 100).round(2)
    elapsed_time = Time.now - start_time
    eta = if processed_files > 0
            (elapsed_time / processed_files) * (total_files - processed_files)
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
    table_renderer = table.render(:ascii, alignments: [:left, :right, :left, :right], padding: [0,1,0,1], width: screen_width)

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

  def format_duration(seconds)
    mm, ss = seconds.divmod(60)
    hh, mm = mm.divmod(60)
    "%02d:%02d:%02d" % [hh, mm, ss]
  end

  # Print a visual progress bar
  def print_progress_bar(percentage, screen_width)
    bar_width = screen_width - 20
    filled_length = (percentage / 100.0 * bar_width).round
    bar = '█' * filled_length + '-' * (bar_width - filled_length)
    puts "[#{bar}] #{percentage}%"
  end

  # Collect metrics from a single Ruby file.
  def collect_file_metrics(file)
    file_metrics = {
      loc: 0,
      methods: [],
      classes: 0,
      issues: [],
      comments: 0
    }

    begin
      content = File.read(file)
      loc = content.lines.count

      # Skip files with fewer lines than the minimum LOC
      if loc < @options[:min_loc]
        @mutex.synchronize { @line_counts << loc }
        return
      end

      buffer = Parser::Source::Buffer.new(file)
      buffer.source = content
      parser = Parser::CurrentRuby.new

      # Suppress parser warnings during parsing
      old_stderr = $stderr
      $stderr = StringIO.new

      ast = parser.parse(buffer)

      $stderr = old_stderr

      file_metrics[:loc] = loc
      file_metrics[:comments] = count_comments(content)

      visitor = MetricsVisitor.new(file_metrics, @options)
      visitor.process(ast) if ast

      # Calculate file-level metrics
      file_metrics[:maintainability_index] = calculate_file_maintainability_index(file_metrics)
      file_metrics[:comment_density] = calculate_comment_density(file_metrics)
      file_metrics[:duplication] = calculate_code_duplication(content)
    rescue Parser::SyntaxError => e
      @logger.error("Syntax error in #{file}: #{e.message}".colorize(:red))
      file_metrics[:issues] << "Syntax error: #{e.message}"
    rescue => e
      @logger.error("Error processing #{file}: #{e.message}".colorize(:red))
      file_metrics[:issues] << "Processing error: #{e.message}"
    ensure
      @mutex.synchronize do
        @metrics[file] = file_metrics
        @line_counts << file_metrics[:loc]
        @comment_ratios << file_metrics[:comment_density] if file_metrics[:comment_density]
        @duplication_ratios << file_metrics[:duplication] if file_metrics[:duplication]
        # Collect cyclomatic complexity data
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
            @logger.info("New max cyclomatic complexity: #{@max_complexity} in #{file}".colorize(:yellow))
          end
        end
      end
    end
  end

  # Generate reports in specified formats.
  def generate_reports
    Dir.mkdir(@options[:output_dir]) unless Dir.exist?(@options[:output_dir])

    if @options[:output_format].include?(:json)
      json_report_path = File.join(@options[:output_dir], 'metrics_report.json')
      File.write(json_report_path, JSON.pretty_generate(@metrics))
      @logger.info("JSON report generated at #{json_report_path}".colorize(:green))
    end

    if @options[:output_format].include?(:csv)
      csv_report_path = File.join(@options[:output_dir], 'metrics_report.csv')
      generate_csv_report(csv_report_path)
      @logger.info("CSV report generated at #{csv_report_path}".colorize(:green))
    end

    if @options[:output_to_console]
      output_metrics_to_console
    end

    if @options[:output_file]
      File.write(@options[:output_file], JSON.pretty_generate(@metrics))
      @logger.info("Metrics written to #{@options[:output_file]}".colorize(:green))
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
          average_cyclomatic_complexity(data),
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
    require 'terminal-table'

    # Limit output to top 10 files with highest cyclomatic complexity
    top_files = @metrics.sort_by do |_file, data|
      -average_cyclomatic_complexity(data)
    end.first(10)

    rows = top_files.map do |file, data|
      [
        truncate(file, 80),
        data[:loc],
        data[:classes],
        data[:methods].size,
        average_cyclomatic_complexity(data),
        data[:maintainability_index],
        data[:issues].size
      ]
    end

    table = Terminal::Table.new(
      title: "Top 10 Files by Cyclomatic Complexity".colorize(:light_magenta),
      headings: [
        'File'.colorize(:cyan),
        'LOC'.colorize(:cyan),
        'Cls'.colorize(:cyan),
        'Mth'.colorize(:cyan),
        'Avg Cmplx'.colorize(:cyan),
        'MI'.colorize(:cyan),
        'Issues'.colorize(:cyan)
      ],
      rows: rows
    )

    table.style = { width: @options[:max_output_width], alignment: :left }
    table.align_column(1, :right)   # LOC
    table.align_column(2, :center)  # Classes
    table.align_column(3, :center)  # Methods
    table.align_column(4, :center)  # Avg Complexity
    table.align_column(5, :center)  # MI
    table.align_column(6, :center)  # Issues

    puts "\nTop 10 Files by Cyclomatic Complexity:".colorize(:light_blue)
    puts "(High complexity methods can be difficult to maintain. Consider refactoring these methods to simplify them.)".colorize(:yellow)
    puts table

    # Collect all issues across all files
    all_issues = []
    @metrics.each do |file, data|
      data[:issues].each do |issue|
        all_issues << {
          file: file,
          issue: issue,
          complexity: average_cyclomatic_complexity(data),
          maintainability_index: data[:maintainability_index],
          loc: data[:loc]
        }
      end
    end

    # Sort issues by cyclomatic complexity (descending)
    top_issues = all_issues.sort_by { |issue| -issue[:complexity] }.first(3)

    # Present top 3 issues with detailed information
    if top_issues.any?
      puts "\nTop 3 Issues with Full Details:".colorize(:light_blue)
      top_issues.each_with_index do |issue, index|
        begin
          puts "\nIssue ##{index + 1}".colorize(:light_blue)
          puts "File: #{issue[:file]}".colorize(:cyan)
          issue_text = truncate(issue[:issue], 80)
          issue_rows = [
            [
              'Issue'.colorize(:cyan),
              'Complexity'.colorize(:cyan),
              'MI'.colorize(:cyan),
              'LOC'.colorize(:cyan)
            ],
            [
              issue_text,
              issue[:complexity],
              issue[:maintainability_index],
              issue[:loc]
            ]
          ]
          issue_table = Terminal::Table.new(rows: issue_rows)
          issue_table.style = {
            width: @options[:max_output_width],
            alignment: :left,
            all_separators: true
          }
          # Set column widths directly on the table
          issue_table.column_widths = [(@options[:max_output_width] * 0.5).to_i, 15, 10, 10]
          puts issue_table
        rescue => e
          @logger.error("Error displaying issue ##{index + 1}: #{e.message}".colorize(:red))
        end
      end
    else
      puts "\nNo issues detected.".colorize(:green)
    end

    # Now, create ASCII charts to show distributions
    puts "\nLOC Distribution per File:".colorize(:light_blue)
    begin
      loc_distribution_chart
    rescue => e
      @logger.error("Error generating LOC Distribution chart: #{e.message}".colorize(:red))
    end

    puts "\nCyclomatic Complexity Distribution:".colorize(:light_blue)
    begin
      cyclomatic_complexity_distribution_chart
    rescue => e
      @logger.error("Error generating Cyclomatic Complexity chart: #{e.message}".colorize(:red))
    end

    puts "\nComment Density Across Files (%):".colorize(:light_blue)
    begin
      comment_density_distribution_chart
    rescue => e
      @logger.error("Error generating Comment Density chart: #{e.message}".colorize(:red))
    end

    puts "\nCode Duplication in Files (%):".colorize(:light_blue)
    begin
      code_duplication_distribution_chart
    rescue => e
      @logger.error("Error generating Code Duplication chart: #{e.message}".colorize(:red))
    end
  end

  # Create LOC distribution chart
  def loc_distribution_chart
    bucket_size = 50
    histogram_data = Hash.new(0)
    @line_counts.each do |loc|
      bucket = ((loc.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }.first(10).to_h

    plot = UnicodePlot.barplot(sorted_data.keys.map(&:to_s), sorted_data.values, title: "LOC Distribution", xlabel: "LOC Range", ylabel: "Files")
    puts plot.render
  end

  # Create cyclomatic complexity distribution chart
  def cyclomatic_complexity_distribution_chart
    bucket_size = 1
    histogram_data = Hash.new(0)
    @complexity_counts.each do |complexity|
      bucket = ((complexity.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }.first(10).to_h

    plot = UnicodePlot.barplot(sorted_data.keys.map(&:to_s), sorted_data.values, title: "Cyclomatic Complexity Distribution", xlabel: "Complexity", ylabel: "Methods")
    puts plot.render
  end

  # Create comment density distribution chart
  def comment_density_distribution_chart
    bucket_size = 10
    histogram_data = Hash.new(0)
    @comment_ratios.each do |ratio|
      bucket = ((ratio.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }.first(10).to_h

    plot = UnicodePlot.barplot(sorted_data.keys.map { |k| "#{k}%" }, sorted_data.values, title: "Comment Density", xlabel: "Density Range", ylabel: "Files")
    puts plot.render
  end

  # Create code duplication distribution chart
  def code_duplication_distribution_chart
    bucket_size = 5
    histogram_data = Hash.new(0)
    @duplication_ratios.each do |ratio|
      bucket = ((ratio.to_f / bucket_size).floor) * bucket_size
      histogram_data[bucket] += 1
    end

    sorted_data = histogram_data.sort_by { |bucket, _| bucket }.first(10).to_h

    plot = UnicodePlot.barplot(sorted_data.keys.map { |k| "#{k}%" }, sorted_data.values, title: "Code Duplication", xlabel: "Duplication %", ylabel: "Files")
    puts plot.render
  end

  # Calculate average cyclomatic complexity for a file.
  def average_cyclomatic_complexity(data)
    complexities = data[:methods].map { |m| m[:cyclomatic_complexity] }
    return 0 if complexities.empty?
    (complexities.sum.to_f / complexities.size).round(2)
  end

  # Calculate the maintainability index for the entire file.
  def calculate_file_maintainability_index(data)
    total_volume = data[:methods].sum { |m| m[:halstead][:volume] || 0 }
    total_cyclomatic_complexity = data[:methods].sum { |m| m[:cyclomatic_complexity] || 0 }
    loc = data[:loc] || 0

    mi = 171 - 5.2 * Math.log(volume_nonzero(total_volume)) - 0.23 * total_cyclomatic_complexity - 16.2 * Math.log(loc_nonzero(loc))
    mi = [[mi, 0].max, 100].min
    mi.round(2)
  end

  # Handle zero values in logarithms
  def volume_nonzero(volume)
    volume > 0 ? volume : 1
  end

  def loc_nonzero(loc)
    loc > 0 ? loc : 1
  end

  # Calculate comment density for a file
  def calculate_comment_density(data)
    comment_lines = data[:comments]
    loc = data[:loc]
    return 0 if loc.zero?
    ((comment_lines.to_f / loc) * 100).round(2)
  end

  # Count comment lines in the content
  def count_comments(content)
    content.lines.count { |line| line.strip.start_with?('#') }
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

  # Get peak memory usage in MB
  def get_peak_memory_usage
    # Approximate current memory usage
    memory_usage_kb = `ps -o rss= -p #{Process.pid}`.to_i
    (memory_usage_kb / 1024.0).round(2)
  end

  # Report files with long processing times
  def report_slow_files
    slow_files = @file_processing_times.sort_by { |_file, time| -time }.first(5)
    if slow_files.any?
      puts "\nFiles with Long Processing Time:".colorize(:light_blue)
      rows = slow_files.map do |file, time|
        [
          truncate(file, 40),
          format('%.2f', time)
        ]
      end

      table = Terminal::Table.new(
        headings: ['File'.colorize(:cyan), 'Time (s)'.colorize(:cyan)],
        rows: rows
      )
      table.style = { width: @options[:max_output_width], alignment: :left }
      puts table
    end
  end

  # Truncate a string to a maximum length
  def truncate(string, max_length)
    if string.length > max_length
      string[0...max_length - 3] + '...'
    else
      string
    end
  end
end

# MetricsVisitor traverses the AST and collects metrics.
class MetricsVisitor < Parser::AST::Processor
  def initialize(file_metrics, options)
    @file_metrics = file_metrics
    @options = options
    @current_nesting = 0
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

    if %i[if while until for rescue when and or case].include?(node.type)
      complexity += 1
    end

    node.children.reduce(complexity) do |comp, child|
      traverse_for_complexity(child, comp)
    end
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
        calculate_halstead_metrics(child, metrics)
      end
    end

    n1 = metrics[:operators].size
    n2 = metrics[:operands].size
    n1_total = metrics[:operator_count]
    n2_total = metrics[:operand_count]
    vocabulary = n1 + n2
    length = n1_total + n2_total

    metrics[:volume] = if vocabulary > 0
      length * Math.log2(vocabulary)
    else
      0
    end

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
      child_depth = calculate_max_nesting_depth(child, depth)
      max_depth = [max_depth, child_depth].max
    end

    max_depth
  end

  # Calculate lines of code for a method.
  def calculate_loc(node)
    return 0 unless node.is_a?(Parser::AST::Node)
    start_line = node.loc.expression.line
    end_line = node.loc.expression.last_line
    end_line - start_line + 1
  rescue
    0
  end

  # Calculate maintainability index.
  def calculate_maintainability_index(cyclomatic_complexity, volume, loc)
    volume ||= 0
    loc ||= 0
    mi = 171 - 5.2 * Math.log(volume_nonzero(volume)) - 0.23 * cyclomatic_complexity - 16.2 * Math.log(loc_nonzero(loc))
    mi = [[mi, 0].max, 100].min
    mi.round(2)
  end

  # Handle zero values in logarithms
  def volume_nonzero(volume)
    volume > 0 ? volume : 1
  end

  def loc_nonzero(loc)
    loc > 0 ? loc : 1
  end

  # Detect code smells and add issues to the file metrics.
  def detect_code_smells(method_name, cyclomatic_complexity, max_nesting_depth, params_count)
    if cyclomatic_complexity > (@options[:thresholds][:cyclomatic_complexity] || 10)
      @file_metrics[:issues] << "High complexity in '#{method_name}' (#{cyclomatic_complexity})."
    end

    if max_nesting_depth > (@options[:thresholds][:nesting_depth] || 5)
      @file_metrics[:issues] << "Deep nesting in '#{method_name}' (#{max_nesting_depth} levels)."
    end

    if params_count > (@options[:thresholds][:parameters] || 4)
      @file_metrics[:issues] << "Too many parameters in '#{method_name}' (#{params_count})."
    end
  end
end

# Parse command-line options and run the collector
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ./code_metrics_collector.rb -d DIRECTORY [options]"

  opts.on("-d", "--directory PATH", "Directory to analyze") do |d|
    options[:directory] = d
  end

  opts.on("-o", "--output-dir DIR", "Directory to save reports (default: metrics_reports)") do |o|
    options[:output_dir] = o
  end

  opts.on("--output-file FILE", "File to save metrics report") do |f|
    options[:output_file] = f
  end

  opts.on("-f", "--format FORMAT", "Output format (json,csv) (default: json,csv)") do |f|
    options[:output_format] = f.split(',').map(&:to_sym)
  end

  opts.on("-t", "--threads COUNT", Integer, "Number of threads (default: 4)") do |t|
    options[:thread_count] = t
  end

  opts.on("-l", "--log-level LEVEL", "Log level (DEBUG, INFO, WARN, ERROR) (default: INFO)") do |l|
    options[:log_level] = Logger.const_get(l.upcase)
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
    options[:thresholds][key.to_sym] = value.to_i
  end

  opts.on("--no-console-output", "Disable output to console") do
    options[:output_to_console] = false
  end

  opts.on("--min-loc VALUE", Integer, "Minimum LOC to analyze a file (default: 100)") do |value|
    options[:min_loc] = value
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

# Validate required options.
unless options[:directory]
  puts "Error: Directory is required."
  puts "Usage: ./code_metrics_collector.rb -d /path/to/your/project"
  exit 1
end

# Run the collector.
collector = CodeMetricsCollector.new(options[:directory], options)
metrics = collector.collect_metrics
