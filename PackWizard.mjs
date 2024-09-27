#!/usr/bin/env node

/**
 * PackWizard™ - Updated Version
 *
 * 🧙‍♂️✨ "Even more magical!" ✨🧙‍♂️
 *
 * New Features:
 * - Identifies and removes unnecessary dependencies
 * - Detects dependencies with incorrect versions
 * - Checks for missing or needed changes in package.json
 *
 * Usage:
 *   packwizard [options] [directory]
 *
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
const traverse = require("@babel/traverse").default;

const config = {
	defaultExcludeDirs: ["node_modules", ".git", "coverage", "dist", "build"],
	defaultVersionStrategy: "latest",
	defaultRootDir: ".",
	defaultOutputFile: "package.json",
};

const spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
let spinnerIndex = 0;
let spinnerInterval;

function startSpinner() {
	spinnerInterval = setInterval(() => {
		process.stdout.write(`\r${spinnerFrames[spinnerIndex]} Scanning files...`);
		spinnerIndex = (spinnerIndex + 1) % spinnerFrames.length;
	}, 100);
}

function stopSpinner() {
	clearInterval(spinnerInterval);
	process.stdout.write("\r✓ Scanning complete!\n");
}

program
	.version("2.2.0")
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

if (program.args.length === 0) {
	program.help();
}

const options = program.opts();
const rootDir = program.args[0] || ".";
const packageJsonPath = path.resolve(rootDir, options.output);
const excludedDirs = new Set(options.exclude.split(",").map((dir) => dir.trim()));
const versionStrategy = options.versionStrategy.toLowerCase();
const isDryRun = options.dryRun || false;
const isVerbose = options.verbose || false;

const dependencies = new Set();

const log = (message) => {
	if (isVerbose) {
		console.log(`[PackWizard™] ${message}`);
	}
};

function getPackageName(importPath) {
	if (importPath.startsWith(".")) return null;
	const parts = importPath.split("/");
	if (importPath.startsWith("@") && parts.length > 1) {
		return `${parts[0]}/${parts[1]}`;
	}
	return parts[0];
}

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
				plugins: ["jsx", "typescript", "dynamicImport"],
			});
		} catch (parseError) {
			console.error(`[PackWizard™] Parsing error in file ${filePath}: ${parseError.message}`);
			return;
		}

		if (ast) {
			traverse(ast, {
				ImportDeclaration({ node }) {
					const packageName = getPackageName(node.source.value);
					if (packageName) {
						log(`Found dependency "${packageName}" in file ${filePath}`);
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
							log(`Found dependency "${packageName}" in file ${filePath}`);
							dependencies.add(packageName);
						}
					}
				},
				Import({ node }) {
					const argument = node.arguments[0];
					if (argument && argument.type === "StringLiteral") {
						const packageName = getPackageName(argument.value);
						if (packageName) {
							log(`Found dependency "${packageName}" in file ${filePath}`);
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

async function traverseDirectory(dir) {
	try {
		const entries = await fs.readdir(dir, { withFileTypes: true });
		for (const entry of entries) {
			const entryPath = path.join(dir, entry.name);

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

async function mergeDependencies(existingPackageJson) {
	existingPackageJson.dependencies = existingPackageJson.dependencies || {};

	for (const dep of dependencies) {
		if (!existingPackageJson.dependencies[dep]) {
			const version = await assignVersion(dep);
			existingPackageJson.dependencies[dep] = version;
			log(`Detected new dependency: ${dep} with version ${version}`);
		} else {
			const existingVersion = existingPackageJson.dependencies[dep];
			const latestVersion = await getLatestVersion(dep);
			if (existingVersion !== latestVersion) {
				log(
					`Version mismatch detected for ${dep}: existing ${existingVersion}, should be ${latestVersion}`,
				);
				existingPackageJson.dependencies[dep] = await assignVersion(dep);
			}
		}
	}

	// Identify dependencies to remove
	const dependenciesToRemove = [];
	for (const dep of Object.keys(existingPackageJson.dependencies)) {
		if (!dependencies.has(dep)) {
			log(`Dependency "${dep}" is not used in the project and will be removed.`);
			dependenciesToRemove.push(dep);
		}
	}

	return { mergedPackageJson: existingPackageJson, dependenciesToRemove };
}

async function confirmChanges(
	newPackageJson,
	existingPackageJson,
	dependenciesToRemove,
	dryRun = false,
) {
	const currentDependencies = existingPackageJson.dependencies || {};
	const detectedDependencies = newPackageJson.dependencies || {};

	const dependenciesToAddOrUpdate = {};

	// Identify dependencies to add or update
	for (const [dep, version] of Object.entries(detectedDependencies)) {
		if (!currentDependencies[dep]) {
			dependenciesToAddOrUpdate[dep] = version;
		} else if (currentDependencies[dep] !== version) {
			dependenciesToAddOrUpdate[dep] = version;
		}
	}

	// If changes are detected, display the table and JSON diff
	if (Object.keys(dependenciesToAddOrUpdate).length > 0 || dependenciesToRemove.length > 0) {
		console.log("\n🔥🔥🔥 *Prepare for Awesomeness!* 🔥🔥🔥");
		console.log("✨ *Here's what your shiny new `package.json` will look like:* ✨\n");

		// Display the before and after `package.json`
		console.log("💻 *Before:*");
		console.log(JSON.stringify(existingPackageJson, null, 2));
		console.log("\n🚀 *After:*");
		console.log(JSON.stringify(newPackageJson, null, 2));

		// Show the delta
		console.log("\n🔄 *Delta (Changes):*");
		const deltaAdd = Object.keys(dependenciesToAddOrUpdate).map((dep) =>
			currentDependencies[dep]
				? `~ ${dep}: ${dependenciesToAddOrUpdate[dep]}`
				: `+ ${dep}: ${dependenciesToAddOrUpdate[dep]}`,
		);
		const deltaRemove = dependenciesToRemove.map((dep) => `- ${dep}`);
		console.log(deltaAdd.concat(deltaRemove).join("\n"));

		if (dryRun) {
			console.log("\n🔍 *This is just a dry run, so no changes will be made.*");
			console.log("💡 *Run without `--dry-run` to make these magical changes for real!*");
			return false;
		}

		// Prompt the user to confirm changes in a regular run
		const proceed = await customConfirmPrompt("💥 Ready to make it happen? (Y/n) ");
		return proceed ? { dependenciesToAddOrUpdate, dependenciesToRemove } : false;
	}

	// If no changes were detected
	console.log("✨ Woohoo! Your `package.json` is already up to date! ✨");
	return false;
}

async function writePackageJson(existingPackageJson, changes) {
	const { dependenciesToAddOrUpdate, dependenciesToRemove } = changes;

	const updatedPackageJson = { ...existingPackageJson };

	// Remove unneeded dependencies
	for (const dep of dependenciesToRemove) {
		delete updatedPackageJson.dependencies[dep];
	}

	// Add or update dependencies
	for (const [dep, version] of Object.entries(dependenciesToAddOrUpdate)) {
		updatedPackageJson.dependencies[dep] = version;
	}

	try {
		if (isDryRun) {
			console.log("--- Dry Run Complete ---");
			console.log("This is how your package.json would look:");
			console.log(JSON.stringify(updatedPackageJson, null, 2));
			return;
		}

		// Create a backup of the existing package.json
		let backupCreated = false;
		try {
			await fs.copyFile(packageJsonPath, `${packageJsonPath}.backup`);
			log(`Backup of existing package.json created at ${packageJsonPath}.backup`);
			backupCreated = true;
		} catch (backupError) {
			if (backupError.code !== "ENOENT") {
				console.error(`[PackWizard™] Error creating backup: ${backupError.message}`);
				process.exit(1);
			}
		}

		// Write the updated package.json
		await fs.writeFile(packageJsonPath, JSON.stringify(updatedPackageJson, null, 2), "utf-8");
		console.log(`🎉 package.json has been successfully updated at ${packageJsonPath} 🎉`);

		// Remove the backup if the file was successfully written
		if (backupCreated) {
			try {
				await fs.unlink(`${packageJsonPath}.backup`);
				log(`Backup removed at ${packageJsonPath}.backup`);
			} catch (unlinkError) {
				console.error(`[PackWizard™] Error removing backup: ${unlinkError.message}`);
			}
		}
	} catch (error) {
		console.error(`[PackWizard™] Error writing package.json: ${error.message}`);
		process.exit(1);
	}
}

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

// Check for other necessary fields (like "scripts", "main", etc.)
function checkForMissingFields(packageJson) {
	if (!packageJson.scripts) {
		log("Warning: 'scripts' field is missing in package.json.");
		packageJson.scripts = {
			test: 'echo "Error: no test specified" && exit 1',
		};
	}

	if (!packageJson.main) {
		log("Warning: 'main' field is missing in package.json.");
		packageJson.main = "index.js";
	}

	// Add more checks as necessary for your project.
}

(async () => {
	// Start the spinner before starting traversal
	startSpinner();

	await traverseDirectory(rootDir);

	const existingPackageJson = await readExistingPackageJson();
	const { mergedPackageJson, dependenciesToRemove } = await mergeDependencies(
		JSON.parse(JSON.stringify(existingPackageJson)),
	);

	checkForMissingFields(mergedPackageJson);

	// Stop the spinner after traversal is complete
	stopSpinner();

	const changes = await confirmChanges(
		mergedPackageJson,
		existingPackageJson,
		dependenciesToRemove,
		isDryRun,
	);

	if (changes && !isDryRun) {
		await writePackageJson(existingPackageJson, changes);
	} else if (!changes && !isDryRun) {
		console.log("🚫 No modifications were made. Your project is still awesome!");
	}
})();
