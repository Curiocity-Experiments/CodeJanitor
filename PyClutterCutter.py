#!/usr/bin/env python3

import os
import ast
import sys
import fnmatch
import shutil
import importlib.util
import yaml
import argparse
from pathlib import Path
from datetime import datetime
import multiprocessing
import tty
import termios

# Version check and compatibility
REQUIRED_PYTHON_VERSION = (3, 6)
if sys.version_info < REQUIRED_PYTHON_VERSION:
    print(f"Warning: This script is designed for Python {'.'.join(map(str, REQUIRED_PYTHON_VERSION))} and above.")
    print(f"You're running Python {'.'.join(map(str, sys.version_info[:3]))}.")
    print("Some features may not work as expected.")

print(f"Running PyClutterCutter with Python {'.'.join(map(str, sys.version_info[:3]))}")

# Configuration options
DEFAULT_CONFIG = {
    'MAIN_FILE': 'app.py',
    'IGNORE_DIRS': {'venv', '.git', '__pycache__', 'node_modules'},
    'EXTENSIONS': {'.py'},
    'SIZE_THRESHOLD': 1024 * 1024,
    'EXCLUDE_SELF': True,
    'ARCHIVE_FOLDER': 'Guido_Gallery',
    'USE_PARALLEL': True,
    'MAX_THREADS': 4
}

def load_config():
    config_path = Path('config.yml')
    if config_path.exists():
        with open(config_path, 'r') as config_file:
            return {**DEFAULT_CONFIG, **yaml.safe_load(config_file)}
    return DEFAULT_CONFIG

CONFIG = load_config()

def parse_gitignore(directory):
    gitignore_path = Path(directory) / '.gitignore'
    ignore_patterns = set()
    if gitignore_path.exists():
        with open(gitignore_path, 'r') as gitignore_file:
            for line in gitignore_file:
                line = line.strip()
                if line and not line.startswith('#'):
                    ignore_patterns.add(line)
    return ignore_patterns

def should_ignore(file_path, ignore_patterns, standard_ignores):
    relative_path = os.path.relpath(file_path, start=os.getcwd())

    for ignore in standard_ignores:
        if relative_path.startswith(ignore):
            return True

    for pattern in ignore_patterns:
        if fnmatch.fnmatch(relative_path, pattern):
            return True

    return False

def get_imported_modules(file_path):
    with open(file_path, 'r') as file:
        tree = ast.parse(file.read())

    imports = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module = node.module if node.module else ''
            for alias in node.names:
                imports.add(f"{module}.{alias.name}")

    return imports

def get_file_info(file_path):
    stat = os.stat(file_path)
    return {
        'size': stat.st_size,
        'created': datetime.fromtimestamp(stat.st_ctime).strftime('%Y-%m-%d %H:%M:%S'),
        'modified': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
    }

def format_size(size):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024.0:
            return f"{size:.2f} {unit}"
        size /= 1024.0
    return f"{size:.2f} TB"

def format_date(date_str):
    date_obj = datetime.strptime(date_str, '%Y-%m-%d %H:%M:%S')
    today = datetime.now().date()
    if date_obj.date() == today:
        return date_obj.strftime('%I:%M %p')
    else:
        return date_obj.strftime('%A, %b %d, %Y')

def print_table(title, headers, rows, widths):
    def print_row(columns, widths):
        return "│ " + " │ ".join(f"{col:<{width}}" for col, width in zip(columns, widths)) + " │"

    def print_separator(widths, corner_left, corner_right, intersection, horizontal='─'):
        return corner_left + intersection.join(horizontal * (w + 2) for w in widths) + corner_right

    total_width = sum(widths) + len(widths) * 3 + 1
    print(f"\n{title}:")
    print(print_separator(widths, '┌', '┐', '┬'))
    print(print_row(headers, widths))
    print(print_separator(widths, '├', '┤', '┼'))
    for row in rows:
        print(print_row(row, widths))
    print(print_separator(widths, '└', '┘', '┴'))

def get_char():
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(sys.stdin.fileno())
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch

def interactive_select(options):
    selected = [False] * len(options)
    current = 0

    def print_menu():
        menu = "\n" + "=" * 50 + "\n"
        menu += "Use ↑ and ↓ to move, SPACE to select/deselect, 'a' to select all, 'n' to deselect all\n"
        menu += "'q' to quit, 'd' to delete selected, 'm' to move selected to archive\n"
        menu += "=" * 50 + "\n"
        for i, option in enumerate(options):
            prefix = '> ' if i == current else '  '
            checkbox = '[x]' if selected[i] else '[ ]'
            menu += f"{prefix}{checkbox} {option}\n"
        menu += f"\nSelected files: {sum(selected)}"
        return menu

    def clear_previous_menu(lines):
        print(f"\033[{lines}A\033[J", end="")

    menu = print_menu()
    print(menu)
    lines = menu.count('\n') + 1

    while True:
        key = get_char()
        if key == '\x1b':
            key += get_char() + get_char()
            if key == '\x1b[A' and current > 0:  # Up arrow
                current -= 1
            elif key == '\x1b[B' and current < len(options) - 1:  # Down arrow
                current += 1
        elif key == ' ':  # Space bar
            selected[current] = not selected[current]
        elif key.lower() == 'a':  # Select all
            selected = [True] * len(options)
        elif key.lower() == 'n':  # Deselect all
            selected = [False] * len(options)
        elif key.lower() == 'q':  # Quit
            return None
        elif key.lower() == 'd':  # Delete
            return [options[i] for i in range(len(options)) if selected[i]], 'delete'
        elif key.lower() == 'm':  # Move to archive
            return [options[i] for i in range(len(options)) if selected[i]], 'archive'

        clear_previous_menu(lines)
        menu = print_menu()
        print(menu)
        lines = menu.count('\n') + 1

def process_file(args):
    file_path, ignore_patterns, standard_ignores, main_file = args
    if (not should_ignore(file_path, ignore_patterns, standard_ignores) and
        any(file_path.endswith(ext) for ext in CONFIG['EXTENSIONS'])):
        file_info = get_file_info(file_path)
        is_main = os.path.basename(file_path) == main_file
        return file_path, file_info, is_main
    return None

def find_unused_files(directory):
    used_files = set()
    all_files = {}
    problematic_imports = set()
    large_files = set()

    ignore_patterns = parse_gitignore(directory)
    current_script = os.path.abspath(__file__)

    file_list = []
    for root, _, files in os.walk(directory):
        for file in files:
            file_path = os.path.join(root, file)
            if not (CONFIG['EXCLUDE_SELF'] and file_path == current_script):
                file_list.append((file_path, ignore_patterns, CONFIG['IGNORE_DIRS'], CONFIG['MAIN_FILE']))

    if CONFIG['USE_PARALLEL']:
        with multiprocessing.Pool(CONFIG['MAX_THREADS']) as pool:
            results = pool.map(process_file, file_list)
    else:
        results = map(process_file, file_list)

    for result in results:
        if result:
            file_path, file_info, is_main = result
            all_files[file_path] = file_info

            if file_info['size'] > CONFIG['SIZE_THRESHOLD']:
                large_files.add(file_path)

            if is_main:
                used_files.add(file_path)
                try:
                    imports = get_imported_modules(file_path)
                    for import_name in imports:
                        try:
                            spec = importlib.util.find_spec(import_name.split('.')[0])
                            if spec and spec.origin:
                                used_files.add(spec.origin)
                        except (ImportError, AttributeError, ModuleNotFoundError) as e:
                            problematic_imports.add((import_name, str(e)))
                except Exception as e:
                    print(f"Error processing {file_path}: {str(e)}")

    unused_files = set(all_files.keys()) - used_files
    return unused_files, problematic_imports, large_files, all_files

def delete_files(files_to_delete):
    for file in files_to_delete:
        try:
            os.remove(file)
            print(f"Deleted: {file}")
        except Exception as e:
            print(f"Error deleting {file}: {str(e)}")

def move_to_archive(files_to_move, archive_folder):
    if not os.path.exists(archive_folder):
        os.makedirs(archive_folder)
    for file in files_to_move:
        try:
            dest = os.path.join(archive_folder, os.path.basename(file))
            shutil.move(file, dest)
            print(f"Moved to archive: {file}")
        except Exception as e:
            print(f"Error moving {file} to archive: {str(e)}")

def parse_arguments():
    parser = argparse.ArgumentParser(description="PyClutterCutter: Clean up unused Python files")
    parser.add_argument("-d", "--dry-run", action="store_true", help="Perform a dry run without making changes")
    return parser.parse_args()

def main():
    args = parse_arguments()
    app_directory = os.path.abspath(".")
    archive_path = os.path.join(app_directory, CONFIG['ARCHIVE_FOLDER'])

    print(f"🐍 PyClutterCutter: Where 'import this' meets 'export that' 🐍")
    print(f"Unraveling the ouroboros of unused code in: {app_directory}")
    print(f"Archive location: {archive_path}")
    print("Channeling our inner Guido to separate the wheat from the __chaff__...")

    unused, problematic, large, all_files = find_unused_files(app_directory)

    if unused:
        unused_rows = [
            [
                os.path.relpath(file, app_directory),
                format_size(all_files[file]['size']),
                format_date(all_files[file]['created']),
                format_date(all_files[file]['modified'])
            ] for file in unused
        ]
        print_table(
            "🕵️ The Graveyard of Good Intentions (aka Unused Files) 🕵️",
            ["File", "Size", "Born On", "Last Breath"],
            unused_rows,
            [40, 10, 25, 25]
        )
    else:
        print("No unused files found. Your codebase is cleaner than a fresh virtualenv! ✨")

    if problematic:
        problematic_rows = [[import_name, error] for import_name, error in problematic]
        print_table(
            "🚨 The 'import antigravity' Hall of Fame 🚨",
            ["Import", "Excuse"],
            problematic_rows,
            [30, 50]
        )

    if large:
        large_rows = [
            [os.path.relpath(file, app_directory), format_size(all_files[file]['size'])]
            for file in large
        ]
        print_table(
            f"🐘 Bytecode Behemoths (Files over {format_size(CONFIG['SIZE_THRESHOLD'])}) 🐘",
            ["File", "Size"],
            large_rows,
            [60, 20]
        )

    print("\n⚠️ Disclaimer: Use with the caution of a zen-master serpent handler! ⚠️")
    print("This script is like a well-intentioned but slightly nearsighted PEP 8 enforcer.")
    print("It might mistake your 'Explicit is better than implicit' for 'Explicit is better in /tmp/'.")
    if unused and not args.dry_run:
            relative_paths = [os.path.relpath(file, app_directory) for file in unused]
            print("\nTime to decide the fate of these digital tumbleweeds.")
            print("Remember: To delete or not to delete, that is the question - whether 'tis nobler in the RAM to suffer...")
            result = interactive_select(relative_paths)

            if result is None:
                print("Operation cancelled faster than a KeyboardInterrupt. No files were harmed in the making of this decision.")
                return

            selected_files, action = result
            files_to_process = [os.path.join(app_directory, file) for file in selected_files]

            if not files_to_process:
                print("No files selected. Your codebase remains as mysterious as the Zen of Python.")
                return

            print(f"\nFiles selected for the great {action}:")
            for file in files_to_process:
                print(f"- {file}")

            confirm = input(f"\nAre you sure you want to {action} these files? This action is more permanent than a global variable. (Y/N): ").lower()
            if confirm == 'y':
                if action == 'delete':
                    print("\nPreparing to send these files to the great /dev/null in the sky:")
                    for file in files_to_process:
                        print(f"os.remove('{file}')  # Goodbye, old friend")

                    final_confirm = input("\nFinal confirmation. Proceed with the digital exorcism? (Y/N): ").lower()
                    if final_confirm == 'y':
                        delete_files(files_to_process)
                        print("\n🧹 Clean-up complete! Your codebase is now lighter than a list comprehension. 🌬️")
                    else:
                        print("\nDeletion cancelled. Your files will live to raise IndentationErrors another day.")
                elif action == 'archive':
                    print(f"\nPreparing to send these files to {archive_path} - where code goes to contemplate its existence.")
                    final_confirm = input("\nFinal confirmation. Proceed with the grand archiving? (Y/N): ").lower()
                    if final_confirm == 'y':
                        move_to_archive(files_to_process, archive_path)
                        print("\n📦 Archiving complete! Your files have been safely tucked away, like comments in thoroughly documented code.")
                    else:
                        print("\nArchiving cancelled. Your files will remain unenlightened about their unused status.")
            else:
                print(f"\n{action.capitalize()} cancelled. Your digital clutter will continue to spark joy and confusion in equal measure.")
    elif args.dry_run:
        print("\nDry run completed. No changes were made to your files.")
    else:
        print("\nNo unused files to process. Your codebase is already more minimalist than `from __future__ import braces`.")

    print("\nRemember: Today's 'unused' file might be tomorrow's 'import antigravity' moment! 🚀🐍")

    if __name__ == "__main__":
        main()
