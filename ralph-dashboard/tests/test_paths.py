from pathlib import Path

import pytest

from ralph_dashboard import paths


@pytest.fixture
def allowlist_root(monkeypatch, tmp_path: Path) -> Path:
    root = tmp_path / "allowed"
    root.mkdir()
    monkeypatch.setattr(paths, "ALLOWED_ROOTS", {"allowed": root})
    return root


def test_clean_relative_path_rejects_absolute_paths() -> None:
    with pytest.raises(ValueError, match="absolute paths are not allowed"):
        paths.clean_relative_path("/etc/passwd")


@pytest.mark.parametrize("candidate", ["..", "nested/../escape"])
def test_clean_relative_path_rejects_parent_segments(candidate: str) -> None:
    with pytest.raises(ValueError, match="path traversal is not allowed"):
        paths.clean_relative_path(candidate)


def test_clean_relative_path_rejects_empty_segments() -> None:
    with pytest.raises(ValueError, match="path traversal is not allowed"):
        paths.clean_relative_path("nested//file")


def test_clean_relative_path_normalizes_relatives() -> None:
    assert paths.clean_relative_path("nested/dir") == Path("nested/dir")
    assert paths.clean_relative_path("nested/./dir/") == Path("nested/dir")
    assert paths.clean_relative_path("") == Path(".")


def test_resolve_allowed_path_rejects_unknown_root(monkeypatch) -> None:
    monkeypatch.setattr(paths, "ALLOWED_ROOTS", {})
    with pytest.raises(ValueError, match="unknown root"):
        paths.resolve_allowed_path("missing", "file.txt")


def test_resolve_allowed_path_rejects_escape_via_symlink(allowlist_root: Path, tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    escape = allowlist_root / "escape"
    escape.symlink_to(outside)
    with pytest.raises(ValueError, match="requested path escapes allowlisted root"):
        paths.resolve_allowed_path("allowed", "escape")


def test_resolve_allowed_path_returns_nested_file(allowlist_root: Path) -> None:
    nested_dir = allowlist_root / "nested" / "dir"
    nested_dir.mkdir(parents=True)
    nested_file = nested_dir / "file.txt"
    nested_file.write_text("content")
    resolved = paths.resolve_allowed_path("allowed", "nested/dir/file.txt")
    assert resolved == nested_file.resolve()


def test_resolve_allowed_path_returns_directories(allowlist_root: Path) -> None:
    nested_dir = allowlist_root / "nested" / "dir"
    nested_dir.mkdir(parents=True)
    assert paths.resolve_allowed_path("allowed", "nested/dir") == nested_dir.resolve()
