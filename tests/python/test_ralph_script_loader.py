#!/usr/bin/env python3
"""Unit tests for the Ralph script loader helper.

Tests loading Python scripts with hyphenated filenames without requiring
them to be importable packages.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import (
    get_ralph_python_dir,
    load_ralph_script,
    load_script_by_path,
)


class TestLoadScriptByPath(unittest.TestCase):
    """Test loading Python scripts by file path."""

    def setUp(self) -> None:
        """Set up temporary test files."""
        self.temp_dir = tempfile.mkdtemp()
        self.addCleanup(self._cleanup_temp_dir)

    def _cleanup_temp_dir(self) -> None:
        """Clean up temporary directory."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_test_script(self, filename: str, content: str) -> Path:
        """Create a test script file."""
        script_path = Path(self.temp_dir) / filename
        script_path.write_text(content, encoding="utf-8")
        return script_path

    def test_load_simple_script(self) -> None:
        """Test loading a simple Python script."""
        script_content = '''
"""A simple test script."""
TEST_VALUE = 42

def hello():
    return "world"
'''
        script_path = self._create_test_script("simple_script.py", script_content)
        module = load_script_by_path(script_path)

        self.assertEqual(module.TEST_VALUE, 42)
        self.assertEqual(module.hello(), "world")

    def test_load_hyphenated_filename(self) -> None:
        """Test loading a script with hyphens in the filename."""
        script_content = '''
"""A hyphenated-name script."""
HYPENATED_VALUE = "test"

def process():
    return "processed"
'''
        script_path = self._create_test_script("my-hyphenated-script.py", script_content)
        module = load_script_by_path(script_path)

        self.assertEqual(module.HYPENATED_VALUE, "test")
        self.assertEqual(module.process(), "processed")

    def test_load_script_with_main_function(self) -> None:
        """Test loading a script with a main function."""
        script_content = '''
"""Script with main function."""
import sys

def main(argv=None):
    args = argv if argv is not None else sys.argv[1:]
    return 0 if args else 1

if __name__ == "__main__":
    raise SystemExit(main())
'''
        script_path = self._create_test_script("main-test-script.py", script_content)
        module = load_script_by_path(script_path)

        self.assertTrue(hasattr(module, 'main'))
        self.assertEqual(module.main(['test']), 0)
        self.assertEqual(module.main([]), 1)

    def test_load_nonexistent_file_raises_error(self) -> None:
        """Test that loading a nonexistent file raises FileNotFoundError."""
        nonexistent_path = Path(self.temp_dir) / "does_not_exist.py"
        with self.assertRaises(FileNotFoundError):
            load_script_by_path(nonexistent_path)

    def test_load_directory_raises_error(self) -> None:
        """Test that loading a directory raises ValueError."""
        with self.assertRaises(ValueError):
            load_script_by_path(self.temp_dir)

    def test_load_relative_path(self) -> None:
        """Test loading a script using a relative path."""
        original_cwd = os.getcwd()
        try:
            os.chdir(self.temp_dir)
            script_content = 'RELATIVE_VALUE = "relative"\n'
            script_path = self._create_test_script("relative_test.py", script_content)

            # Use relative path from temp directory
            relative_path = "relative_test.py"
            module = load_script_by_path(relative_path)

            self.assertEqual(module.RELATIVE_VALUE, "relative")
        finally:
            os.chdir(original_cwd)

    def test_load_script_with_syntax_error(self) -> None:
        """Test that loading a script with syntax error raises ImportError."""
        script_content = 'def broken(  # incomplete function\n'
        script_path = self._create_test_script("broken_syntax.py", script_content)

        with self.assertRaises(ImportError):
            load_script_by_path(script_path)


class TestGetRalphPythonDir(unittest.TestCase):
    """Test getting the Ralph Python directory path."""

    def test_get_ralph_python_dir_default(self) -> None:
        """Test getting Ralph Python dir with default project root."""
        python_dir = get_ralph_python_dir()

        # Should point to bundle/.ralph/python/
        self.assertTrue(python_dir.exists())
        self.assertTrue(python_dir.is_dir())
        self.assertTrue((python_dir / "token_estimate.py").exists())

    def test_get_ralph_python_dir_with_custom_root(self) -> None:
        """Test getting Ralph Python dir with custom project root."""
        # Get the actual project root from the default
        default_root = Path(__file__).parent.parent.parent
        python_dir = get_ralph_python_dir(default_root)

        self.assertTrue(python_dir.exists())
        self.assertEqual(python_dir, default_root / "bundle" / ".ralph" / "python")


class TestLoadRalphScript(unittest.TestCase):
    """Test loading Ralph Python scripts by name."""

    def test_load_token_estimate(self) -> None:
        """Test loading token_estimate.py script."""
        module = load_ralph_script("token_estimate")

        self.assertTrue(hasattr(module, 'estimate_tokens'))
        self.assertTrue(hasattr(module, 'main'))
        # Verify the function works
        self.assertEqual(module.estimate_tokens(""), 0)
        self.assertGreater(module.estimate_tokens("hello world"), 0)

    def test_load_shell_command_rewrite(self) -> None:
        """Test loading shell-command-rewrite.py (hyphenated filename)."""
        module = load_ralph_script("shell-command-rewrite")

        self.assertTrue(hasattr(module, 'main'))
        # Should be able to access imports
        self.assertTrue(hasattr(module, 'json'))

    def test_load_with_py_extension(self) -> None:
        """Test loading script with explicit .py extension."""
        module = load_ralph_script("token_estimate.py")

        self.assertTrue(hasattr(module, 'estimate_tokens'))

    def test_load_nonexistent_script_raises_error(self) -> None:
        """Test that loading a nonexistent script raises FileNotFoundError."""
        with self.assertRaises(FileNotFoundError):
            load_ralph_script("nonexistent_script_xyz")


class TestIntegration(unittest.TestCase):
    """Integration tests verifying the loader works with real Ralph scripts."""

    def test_load_tool_call_classification(self) -> None:
        """Test loading tool_call_classification.py."""
        module = load_ralph_script("tool_call_classification")

        self.assertTrue(hasattr(module, 'classify_tool_calls'))
        self.assertTrue(hasattr(module, 'ACCOUNTING_KEYS'))

    def test_load_shell_command_registry(self) -> None:
        """Test loading shell_command_registry.py."""
        module = load_ralph_script("shell_command_registry")

        self.assertTrue(hasattr(module, 'rewrite_command'))
        self.assertTrue(hasattr(module, 'RewriteResult'))

    def test_loaded_module_independent_instances(self) -> None:
        """Test that loading the same script twice returns independent modules."""
        module1 = load_ralph_script("token_estimate")
        module2 = load_ralph_script("token_estimate")

        # Should be different module objects
        self.assertIsNot(module1, module2)
        # But should have the same functionality
        self.assertEqual(module1.estimate_tokens("test"), module2.estimate_tokens("test"))


if __name__ == "__main__":
    unittest.main()
