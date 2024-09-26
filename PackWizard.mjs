#!/usr/bin/env node

/**
 * PackWizard™
 *
 * 🧙‍♂️✨ "Abracadabra! Watch your package.json magically appear!" ✨🧙‍♂️
 *
 * A magical tool to automatically generate and maintain your package.json by scanning your project's dependencies.
 *
 * Features:
 * - Automatically detects dependencies
 * - Integrates with existing package.json without overwriting
 * - Fetches the latest versions from npm registry
 * - Excludes irrelevant directories like node_modules, .git, coverage, dist, build
 * - Interactive prompts to review changes
 * - Supports custom configuration and version strategies
 *
 * Usage:
 *   packwizard [options] [directory]
 *
 * Options:
 *   -d, --dir <directory>           Root directory to start from (default: current directory)
 *   -o, --output <file>             Output package.json file (default: "package.json")
 *   --exclude <dirs>                Comma-separated list of directories to exclude (default: from config)
 *   --version-strategy <strategy>   Version strategy: latest, caret, tilde, exact (default: from config)
 *   --dry-run                       Simulate the generation process without making changes
 *   --verbose                       Enable verbose logging for debugging purposes
 *   -h, --help                      Display help for command
 */

import { promises as fs } from "fs";
import path from "path";
import { program } from "commander";
import babelParser from "@babel/parser";
import { createRequire } from "module";
import fetch from "node-fetch";
import { createInterface } from "readline";

// Create a require function
const require = createRequire(import.meta.url);

// Import traverse using require
const traverse = require("@babel/traverse").default;

// Configuration Section
const config = {
	defaultExcludeDirs: ["node_modules", ".git", "coverage", "dist", "build"],
	defaultVersionStrategy: "latest",
	defaultRootDir: ".",
	defaultOutputFile: "package.json",
};

// Check if traverse is a function
if (typeof traverse !== "function") {
	throw new Error("traverse is not a function. Please check the import statement.");
}

// Configure CLI options using Commander
program
	.version("2.0.0")
	.description(
		"PackWizard™: Magically generate and maintain your package.json by scanning project dependencies.",
	)
	.argument("[directory]", "Root directory to start from (default: current directory)")
	.option("-o, --output <file>", "Output package.json file", config.defaultOutputFile)
	.option(
		"--exclude <dirs>",
		"Comma-separated list of directories to exclude",
		config.defaultExcludeDirs.join(","),
	)
	.option(
		"--version-strategy <strategy>",
		"Version strategy: latest, caret, tilde, exact",
		config.defaultVersionStrategy,
	)
	.option("--dry-run", "Simulate the generation process without making changes")
	.option("--verbose", "Enable verbose logging for debugging purposes")
	.parse(process.argv);

// Check if any arguments are provided, if not, show help
if (program.args.length === 0) {
	program.help();
}

const options = program.opts();
const rootDir = program.args[0] || ".";

// Resolve directories based on options and config
const packageJsonPath = path.resolve(rootDir, options.output);
const excludedDirs = new Set(options.exclude.split(",").map((dir) => dir.trim()));
const versionStrategy = options.versionStrategy.toLowerCase();
const isDryRun = options.dryRun || false;
const isVerbose = options.verbose || false;

// Initialize dependency sets
const dependencies = new Set();

// Utility function for logging
const log = (message) => {
	if (isVerbose) {
		console.log(`[PackWizard™] ${message}`);
	}
};

// Function to extract the base package name
function getPackageName(importPath) {
	if (importPath.startsWith(".")) return null; // Ignore relative imports
	const parts = importPath.split("/");
	if (importPath.startsWith("@") && parts.length > 1) {
		return `${parts[0]}/${parts[1]}`; // Scoped package
	}
	return parts[0];
}

// Function to fetch the latest version from npm registry
async function getLatestVersion(packageName) {
	try {
		const res = await fetch(`https://registry.npmjs.org/${packageName}/latest`);
		if (!res.ok) throw new Error(`Failed to fetch version for ${packageName}`);
		const data = await res.json();
		return data.version;
	} catch (error) {
		console.warn(
			`[PackWizard™] Warning: Could not fetch version for ${packageName}: ${error.message}`,
		);
		return "latest";
	}
}

// Function to assign versions based on the chosen strategy
async function assignVersion(packageName) {
	switch (versionStrategy) {
		case "caret":
			const caretVersion = await getLatestVersion(packageName);
			return `^${caretVersion}`;
		case "tilde":
			const tildeVersion = await getLatestVersion(packageName);
			return `~${tildeVersion}`;
		case "exact":
			const exactVersion = await getLatestVersion(packageName);
			return exactVersion;
		case "latest":
		default:
			return "latest";
	}
}

async function processFile(filePath) {
	try {
		const content = await fs.readFile(filePath, "utf-8");
		let ast;
		try {
			ast = babelParser.parse(content, {
				sourceType: "unambiguous",
				plugins: [
					"jsx",
					"typescript",
					"dynamicImport",
					// Add other plugins as needed
				],
			});
		} catch (parseError) {
			console.error(`[PackWizard™] Parsing error in file ${filePath}: ${parseError.message}`);
			return; // Skip this file if parsing fails
		}

		if (ast) {
			// Ensure ast is defined before traversing
			traverse(ast, {
				ImportDeclaration({ node }) {
					const packageName = getPackageName(node.source.value);
					if (packageName) {
						dependencies.add(packageName);
					}
				},
				CallExpression({ node }) {
					if (
						node.callee.name === "require" &&
						node.arguments.length === 1 &&
						node.arguments[0].type === "StringLiteral"
					) {
						const packageName = getPackageName(node.arguments[0].value);
						if (packageName) {
							dependencies.add(packageName);
						}
					}
				},
				Import({ node }) {
					const argument = node.arguments[0];
					if (argument && argument.type === "StringLiteral") {
						const packageName = getPackageName(argument.value);
						if (packageName) {
							dependencies.add(packageName);
						}
					}
				},
			});
		} else {
			console.error(`[PackWizard™] AST is not defined for file: ${filePath}`);
		}
	} catch (error) {
		console.error(`[PackWizard™] Error processing file ${filePath}: ${error.message}`);
	}
}

// Recursive function to traverse directories
async function traverseDirectory(dir) {
	try {
		const entries = await fs.readdir(dir, { withFileTypes: true });
		for (const entry of entries) {
			const entryPath = path.join(dir, entry.name);

			// Exclude specified directories
			if (excludedDirs.has(entry.name)) {
				log(`Skipping excluded directory: ${entryPath}`);
				continue;
			}

			if (entry.isDirectory()) {
				log(`Traversing directory: ${entryPath}`);
				await traverseDirectory(entryPath);
			} else if (
				entry.isFile() &&
				[".js", ".jsx", ".ts", ".tsx"].includes(path.extname(entry.name))
			) {
				log(`Processing file: ${entryPath}`);
				await processFile(entryPath);
			}
		}
	} catch (error) {
		console.error(`[PackWizard™] Error traversing directory ${dir}: ${error.message}`);
	}
}

// Function to read existing package.json if it exists
async function readExistingPackageJson() {
	try {
		const existingContent = await fs.readFile(packageJsonPath, "utf-8");
		const existingPackageJson = JSON.parse(existingContent);
		log(`Existing package.json found at ${packageJsonPath}`);
		return existingPackageJson;
	} catch (error) {
		if (error.code === "ENOENT") {
			log("No existing package.json found. A new one will be created.");
			return {
				name: "auto-generated",
				version: "1.0.0",
				dependencies: {},
			};
		} else {
			console.error(`[PackWizard™] Error reading existing package.json: ${error.message}`);
			process.exit(1);
		}
	}
}

// Function to merge detected dependencies with existing ones
async function mergeDependencies(existingPackageJson) {
	existingPackageJson.dependencies = existingPackageJson.dependencies || {};

	for (const dep of dependencies) {
		if (!existingPackageJson.dependencies[dep]) {
			const version = await assignVersion(dep);
			existingPackageJson.dependencies[dep] = version;
		}
	}

	return existingPackageJson;
}

// Function to prompt user for confirmation before making changes
async function confirmChanges(newPackageJson, existingPackageJson) {
	// Determine changes (show all dependencies, including existing ones)
	const allDependencies = {
		...existingPackageJson.dependencies,
		...newPackageJson.dependencies,
	};

	if (isDryRun) {
		console.log("--- Dry Run Summary ---");
		console.log("Full dependencies listing:");
		console.log(JSON.stringify(allDependencies, null, 2));
		console.log("No changes have been made.");
		process.exit(0);
	}

	console.log("✨ PackWizard™ Detected the following dependencies: ✨");
	console.log(JSON.stringify(allDependencies, null, 2));
	const proceed = await customConfirmPrompt(
		"Do you want to apply these changes to package.json? (Y/n) ",
	);

	return proceed;
}

// Function to write the updated package.json
async function writePackageJson(updatedPackageJson) {
	try {
		if (isDryRun) {
			console.log("--- Dry Run Complete ---");
			console.log(JSON.stringify(updatedPackageJson, null, 2));
			return;
		}

		// Create a backup of the existing package.json
		try {
			await fs.copyFile(packageJsonPath, `${packageJsonPath}.backup`);
			log(`Backup of existing package.json created at ${packageJsonPath}.backup`);
		} catch (backupError) {
			if (backupError.code !== "ENOENT") {
				console.error(`[PackWizard™] Error creating backup: ${backupError.message}`);
				process.exit(1);
			}
			// If package.json doesn't exist, no backup is needed
		}

		// Write the updated package.json
		await fs.writeFile(packageJsonPath, JSON.stringify(updatedPackageJson, null, 2), "utf-8");
		console.log(`🎉 package.json has been successfully updated at ${packageJsonPath} 🎉`);
	} catch (error) {
		console.error(`[PackWizard™] Error writing package.json: ${error.message}`);
		process.exit(1);
	}
}

// Function to prompt user for confirmation before making changes
function customConfirmPrompt(question) {
	return new Promise((resolve) => {
		const rl = createInterface({
			input: process.stdin,
			output: process.stdout,
		});

		rl.question(question, (answer) => {
			rl.close();
			resolve(answer.toLowerCase() === "y" || answer.toLowerCase() === "yes");
		});
	});
}

// Main execution flow
(async () => {
	// Traverse directories and capture all dependencies
	await traverseDirectory(rootDir);

	// After capturing, merge with existing package.json
	const existingPackageJson = await readExistingPackageJson();
	const updatedPackageJson = await mergeDependencies(existingPackageJson);

	// Confirm changes before writing
	const proceed = await confirmChanges(updatedPackageJson, existingPackageJson);

	if (proceed) {
		// Write the final package.json
		await writePackageJson(updatedPackageJson);
	} else {
		console.log("🚫 Changes aborted by the user. No modifications were made.");
	}
})();
