#!/bin/bash

# Usage function
usage() {
  echo "Usage: $0 [options] <path_to_analyze>"
  echo ""
  echo "Options:"
  echo "  -h, --help            Display this help message"
  echo "  --no-log              Disable logging to a file"
  echo "  -i, --ignore PATTERN  Add an additional ignore pattern (can be used multiple times)"
  exit 1
}

# Default values
LOG_ENABLED=true
IGNORE_PATTERNS=()

# Parse options
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -h|--help) usage ;;
    --no-log) LOG_ENABLED=false ;;
    -i|--ignore)
      shift
      IGNORE_PATTERNS+=("$1")
      ;;
    *)
      TARGET_DIR="$1"
      ;;
  esac
  shift
done

# Check if target directory is provided
if [ -z "$TARGET_DIR" ]; then
  echo "Error: No path provided to analyze." >&2
  usage
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory '$TARGET_DIR' does not exist." >&2
  exit 1
fi

# Determine the directory where this script resides
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Create a log file if logging is enabled
if $LOG_ENABLED; then
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  LOG_FILE="${SCRIPT_DIR}/analysis_${TIMESTAMP}.log"
  exec > >(tee -i "$LOG_FILE") 2>&1
  echo -e "$(tput setaf 2)Starting Comprehensive Repository Analysis for '$TARGET_DIR'...$(tput sgr0)"
  echo "Log File: $LOG_FILE"
else
  echo -e "$(tput setaf 2)Starting Comprehensive Repository Analysis for '$TARGET_DIR'...$(tput sgr0)"
fi

# Function to handle ignore patterns
handle_ignore() {
  local script_name=$1
  shift
  local additional_ignores=("$@")
  local ignore_options=""
  for pattern in "${additional_ignores[@]}"; do
    ignore_options+=" -i '$pattern'"
  done
  echo "$ignore_options"
}

# Run Directory Structure Analysis
echo -e "\n$(tput setaf 3)--- Directory Structure ---$(tput sgr0)"
DIRECTORY_IGNORE=$(handle_ignore "directory_structure.rb" "${IGNORE_PATTERNS[@]}")
if "$SCRIPT_DIR"/directory_structure.rb "$TARGET_DIR" "${IGNORE_PATTERNS[@]}"; then
  echo -e "$(tput setaf 2)Directory Structure Analysis completed successfully.$(tput sgr0)"
else
  echo -e "$(tput setaf 1)Directory Structure Analysis failed.$(tput sgr0)"
fi

# Run Key Files Identification
echo -e "\n$(tput setaf 3)--- Key Files Identification ---$(tput sgr0)"
if "$SCRIPT_DIR"/identify_key_files.sh "$TARGET_DIR" "${IGNORE_PATTERNS[@]}"; then
  echo -e "$(tput setaf 2)Key Files Identification completed successfully.$(tput sgr0)"
else
  echo -e "$(tput setaf 1)Key Files Identification failed.$(tput sgr0)"
fi

# Run Dependency Analysis
echo -e "\n$(tput setaf 3)--- Dependency Analysis ---$(tput sgr0)"
if "$SCRIPT_DIR"/dependency_analysis.rb "$TARGET_DIR" "${IGNORE_PATTERNS[@]}"; then
  echo -e "$(tput setaf 2)Dependency Analysis completed successfully.$(tput sgr0)"
else
  echo -e "$(tput setaf 1)Dependency Analysis failed.$(tput sgr0)"
fi

# Run Code Metrics and Complexity
echo -e "\n$(tput setaf 3)--- Code Metrics and Complexity ---$(tput sgr0)"
if "$SCRIPT_DIR"/code_metrics.sh "$TARGET_DIR" "${IGNORE_PATTERNS[@]}"; then
  echo -e "$(tput setaf 2)Code Metrics and Complexity Analysis completed successfully.$(tput sgr0)"
else
  echo -e "$(tput setaf 1)Code Metrics and Complexity Analysis failed.$(tput sgr0)"
fi

# Run Documentation Check
echo -e "\n$(tput setaf 3)--- Documentation and README Analysis ---$(tput sgr0)"
if "$SCRIPT_DIR"/documentation_check.sh "$TARGET_DIR" "${IGNORE_PATTERNS[@]}"; then
  echo -e "$(tput setaf 2)Documentation and README Analysis completed successfully.$(tput sgr0)"
else
  echo -e "$(tput setaf 1)Documentation and README Analysis failed.$(tput sgr0)"
fi

# Run Ownership Insights
echo -e "\n$(tput setaf 3)--- Ownership Insights ---$(tput sgr0)"
if "$SCRIPT_DIR"/ownership_insights.rb "$TARGET_DIR" "${IGNORE_PATTERNS[@]}"; then
  echo -e "$(tput setaf 2)Ownership Insights Analysis completed successfully.$(tput sgr0)"
else
  echo -e "$(tput setaf 1)Ownership Insights Analysis failed.$(tput sgr0)"
fi

echo -e "\n$(tput setaf 2)Repository Analysis Completed.$(tput sgr0)"
if $LOG_ENABLED; then
  echo "Check the log file '$LOG_FILE' for details."
fi
