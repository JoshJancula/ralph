"""Helper utilities for tool-eval fixture workspace."""


def helper_sum(values: list[int]) -> int:
    """Return the sum of integer values."""
    return sum(values)


def helper_label() -> str:
    return "tool-eval-helper"
