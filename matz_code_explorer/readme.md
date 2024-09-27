# Matz's Joyful Code Explorer

A delightful Ruby script that analyzes your Ruby projects, providing insights into directory structure, dependencies, code quality, documentation, ownership, and security.

## Features

- **Directory Structure Analysis:** Overview of project file organization.
- **Key Files Identification:** Locates crucial project files.
- **Dependency Analysis:** Examines project dependencies and versions.
- **Code Metrics Analysis:** Evaluates code quality and complexity using RuboCop.
- **Documentation Analysis:** Assesses documentation coverage.
- **Ownership Insights:** Analyzes code contributions by author.
- **Security Analysis:** Checks for potential security vulnerabilities.

## Installation

Ensure you have Ruby installed (version 2.7.6 as detected).

### Without Gemfile

1. **Install Required Gems Globally:**

   ```bash
   gem install rubocop rubocop-performance rubocop-rspec parser brakeman bundler-audit colorize tty-prompt tty-reader
