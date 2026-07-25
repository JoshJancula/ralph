#!/usr/bin/env python3
"""Helper module to load Ralph Python scripts by file path.

Supports hyphenated filenames (e.g., shell-command-rewrite.py) without
requiring those scripts to become importable packages.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType


RalphScriptSpec = ModuleType | None


def load_script_by_path(script_path: str | os.PathLike[str]) -> ModuleType:
    """Load a Python script by its file path.

    This function loads a Python script from the filesystem without requiring
    it to be on the Python path or have a valid module name (supports hyphens).

    Args:
        script_path: Absolute or relative path to the Python script.

    Returns:
        The loaded module object.

    Raises:
        FileNotFoundError: If the script file does not exist.
        ImportError: If the script cannot be loaded or executed.
        ValueError: If the path is empty or not a file.

    Example:
        >>> script = load_script_by_path("bundle/.ralph/python/shell-command-rewrite.py")
        >>> hasattr(script, 'main')
        True
    """
    script_path_obj = Path(script_path).resolve()

    if not script_path_obj.exists():
        raise FileNotFoundError(f"Script not found: {script_path}")

    if not script_path_obj.is_file():
        raise ValueError(f"Path is not a file: {script_path}")

    # Use the filename (without .py) as the module name
    # Importlib spec loading allows hyphens in the module name
    module_name = script_path_obj.stem
    spec = importlib.util.spec_from_file_location(module_name, script_path_obj)

    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load module spec from: {script_path}")

    module = importlib.util.module_from_spec(spec)

    # Store the original sys.modules state
    original_module = sys.modules.get(module_name)

    try:
        # Temporarily add to sys.modules to handle relative imports
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
    except Exception as exc:
        # Clean up on failure
        if module_name in sys.modules:
            del sys.modules[module_name]
        raise ImportError(f"Failed to execute module from {script_path}: {exc}") from exc
    finally:
        # Restore original module if it existed, otherwise keep the loaded one
        if original_module is not None:
            sys.modules[module_name] = original_module
        elif module_name in sys.modules and sys.modules[module_name] is module:
            # Keep the loaded module in sys.modules for subsequent access
            pass
        elif module_name in sys.modules:
            del sys.modules[module_name]

    return module


def get_ralph_python_dir(project_root: str | os.PathLike[str] | None = None) -> Path:
    """Get the path to the Ralph Python scripts directory.

    Args:
        project_root: Optional path to the project root. If not provided,
            attempts to locate it relative to this file.

    Returns:
        Path to bundle/.ralph/python/ directory.
    """
    if project_root is None:
        # Default: traverse from tests/python/ to project root
        # tests/python/ -> tests/ -> project root
        project_root = Path(__file__).parent.parent.parent

    return Path(project_root) / "bundle" / ".ralph" / "python"


def load_ralph_script(script_name: str, project_root: str | os.PathLike[str] | None = None) -> ModuleType:
    """Load a Ralph Python script by its basename.

    Args:
        script_name: The script filename (with or without .py extension).
        project_root: Optional path to the project root.

    Returns:
        The loaded module object.

    Raises:
        FileNotFoundError: If the script does not exist.
        ImportError: If the script cannot be loaded.

    Example:
        >>> script = load_ralph_script("token_estimate.py")
        >>> hasattr(script, 'estimate_tokens')
        True
    """
    python_dir = get_ralph_python_dir(project_root)

    # Ensure .py extension
    if not script_name.endswith(".py"):
        script_name += ".py"

    script_path = python_dir / script_name
    return load_script_by_path(script_path)
