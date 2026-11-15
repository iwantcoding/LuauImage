import argparse
import json
import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = Path(__file__).resolve().with_name("merger.json")
DEFAULT_SOURCE_ROOT = PROJECT_ROOT / "src" / "lua"
DEFAULT_OUTPUT = PROJECT_ROOT / "build" / "lua" / "Image.luau"
MODULE_ID_PATTERN = re.compile(r"[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\Z")
INCLUDE_PATTERN = re.compile(r"\s*--\s*@include(?:\s+(.*?))?\s*\Z")
MODULE_RETURN_PATTERN = re.compile(r"\s*return\s+[A-Za-z_][A-Za-z0-9_]*\s*\Z")
LICENSE_PREFIX_PATTERN = re.compile(
	r"\A[ \t]*--\[\[[\s\S]*?SPDX-License-Identifier: AGPL-3\.0-only[\s\S]*?\]\][ \t]*(?:\r?\n)*"
)


class MergerError(Exception):
	pass


def load_config(config_path):
	try:
		config = json.loads(config_path.read_text(encoding="utf-8"))
	except OSError as error:
		raise MergerError(f"cannot read config '{config_path}': {error}") from error
	except json.JSONDecodeError as error:
		raise MergerError(
			f"invalid JSON in config '{config_path}' at line {error.lineno}: {error.msg}"
		) from error

	if not isinstance(config, dict) or not isinstance(config.get("modules"), list):
		raise MergerError("config must be an object with a 'modules' array")

	modules = config["modules"]
	seen = set()
	for module_id in modules:
		if not isinstance(module_id, str) or not MODULE_ID_PATTERN.fullmatch(module_id):
			raise MergerError(
				f"invalid module ID {module_id!r}; use slash-separated names with no exts"
			)
		if module_id in seen:
			raise MergerError(f"duplicate module '{module_id}' in config")
		seen.add(module_id)

	return modules


def parse_module(source_root, module_id):
	module_path = (source_root / f"{module_id}.luau").resolve()
	try:
		module_path.relative_to(source_root)
	except ValueError as error:
		raise MergerError(f"module '{module_id}' goes outside the source root") from error

	try:
		source = module_path.read_text(encoding="utf-8")
	except OSError as error:
		raise MergerError(f"unable to read module '{module_id}' at '{module_path}': {error}") from error
	except UnicodeDecodeError as error:
		raise MergerError(f"module '{module_id}' is not valid UTF-8") from error

	dependencies = []
	source_lines = []
	for line_number, line in enumerate(source.splitlines(), start=1):
		include_match = INCLUDE_PATTERN.fullmatch(line)
		if include_match is None:
			source_lines.append(line)
			continue

		included_id = include_match.group(1)
		if included_id is not None and included_id.startswith("<") and included_id.endswith(">"):
			included_id = included_id[1:-1]
		if included_id is None or not MODULE_ID_PATTERN.fullmatch(included_id):
			raise MergerError(
				f"{module_id}.luau:{line_number}: expected '-- @include module/path'"
			)
		dependencies.append(included_id)

	return dependencies, "\n".join(source_lines).rstrip("\n")


def validate_and_load_modules(config_path, source_root):
	modules = load_config(config_path)
	source_root = source_root.resolve()
	if not source_root.is_dir():
		raise MergerError(f"source root does not exist or is not a directory: '{source_root}'")

	module_sources = {}
	dependencies = {}
	configured_modules = set(modules)

	for module_id in modules:
		module_dependencies, module_source = parse_module(source_root, module_id)
		unconfigured = [dep for dep in module_dependencies if dep not in configured_modules]
		if unconfigured:
			raise MergerError(
				f"module '{module_id}' includes '{unconfigured[0]}', which is not listed in config"
			)
		dependencies[module_id] = module_dependencies
		module_sources[module_id] = module_source

	detect_cycles(modules, dependencies)

	module_positions = {module_id: index for index, module_id in enumerate(modules)}
	for module_id in modules:
		for dependency in dependencies[module_id]:
			if module_positions[dependency] >= module_positions[module_id]:
				raise MergerError(
					f"invalid module order: '{module_id}' includes '{dependency}', "
					f"but '{dependency}' must appear earlier in the config"
				)

	return modules, module_sources


def detect_cycles(modules, dependencies):
	states = {}
	traversal = []

	def visit(module_id):
		states[module_id] = 1
		traversal.append(module_id)
		for dependency in dependencies[module_id]:
			if states.get(dependency) == 1:
				cycle_start = traversal.index(dependency)
				cycle = traversal[cycle_start:] + [dependency]
				raise MergerError(f"include cycle detected: {' -> '.join(cycle)}")
			if states.get(dependency, 0) == 0:
				visit(dependency)
		traversal.pop()
		states[module_id] = 2

	for module_id in modules:
		if states.get(module_id, 0) == 0:
			visit(module_id)


def render_bundle(modules, module_sources):
	sections = ["""--[[
    MIT License

    See the LICENSE file in the root of this project
    for the full license text.
]]""", "-- This is auto merged, don't edit it manually"]
	license_prefix = None
	for module_id in modules:
		source_lines = module_sources[module_id].splitlines()
		license_match = LICENSE_PREFIX_PATTERN.match("\n".join(source_lines))
		if license_match is not None:
			if license_prefix is None:
				license_prefix = license_match.group().rstrip("\r\n")
			source_lines = license_match.string[license_match.end():].splitlines()
		if source_lines and MODULE_RETURN_PATTERN.fullmatch(source_lines[-1]):
			source_lines.pop()
		sections.append(f"-- Module: {module_id}")
		sections.append("\n".join(source_lines).rstrip("\n"))
	if license_prefix is not None:
		sections.insert(1, license_prefix)
	return "\n\n".join(sections).rstrip("\n") + "\n"


def merge(config_path, source_root, output_path):
	modules, module_sources = validate_and_load_modules(config_path, source_root)
	output_path.parent.mkdir(parents=True, exist_ok=True)
	output_path.write_text(render_bundle(modules, module_sources), encoding="utf-8", newline="\n")
	return len(modules)


def main(argv=None):
	parser = argparse.ArgumentParser(description="Merge the given modules")
	parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
	parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
	parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
	args = parser.parse_args(argv)

	try:
		module_count = merge(args.config, args.source_root, args.output)
	except MergerError as error:
		print(f"Merger error: {error}", file=sys.stderr)
		return 1
	except OSError as error:
		print(f"Merger error: {error}", file=sys.stderr)
		return 1

	print(f"Merged {module_count} module(s) into '{args.output}'")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
