import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from artifact_provenance import (  # noqa: E402
    ProvenanceError,
    parse_markdown_citations,
    validate_artifact_citation,
    validate_artifact_provenance_file,
    validate_file_line_citation,
    validate_json_provenance,
    validate_markdown_provenance,
    verify_stage_artifact_provenance,
)


class ProvenanceCitationParseTests(unittest.TestCase):
    def test_parse_markdown_list_and_inline_citations(self) -> None:
        text = "\n".join(
            [
                "## Findings",
                "The runner validates schemas. cite:bundle/.ralph/orchestrator.sh:829",
                "",
                "## Citations",
                '- cite: bundle/.ralph/run-plan.sh:10 "run plan"',
            ]
        )
        refs = [ref for ref, _ in parse_markdown_citations(text)]
        self.assertEqual(
            refs,
            [
                "bundle/.ralph/orchestrator.sh:829",
                'bundle/.ralph/run-plan.sh:10 "run plan"',
            ],
        )


class ProvenanceValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.workspace = self._tmpdir.name
        self.source_rel = "src/example.py"
        self.source_abs = os.path.join(self.workspace, self.source_rel)
        os.makedirs(os.path.dirname(self.source_abs), exist_ok=True)
        with open(self.source_abs, "w", encoding="utf-8") as handle:
            handle.write("alpha\nbeta line\n")

    def tearDown(self) -> None:
        self._tmpdir.cleanup()

    def test_valid_file_citation_passes(self) -> None:
        validate_file_line_citation(self.workspace, f"{self.source_rel}:2")

    def test_missing_file_fails(self) -> None:
        with self.assertRaises(ProvenanceError):
            validate_file_line_citation(self.workspace, "missing.py:1")

    def test_out_of_range_line_fails(self) -> None:
        with self.assertRaises(ProvenanceError):
            validate_file_line_citation(self.workspace, f"{self.source_rel}:99")

    def test_traversal_path_fails(self) -> None:
        with self.assertRaises(ProvenanceError):
            validate_file_line_citation(self.workspace, "../outside.py:1")

    def test_excerpt_mismatch_fails(self) -> None:
        with self.assertRaises(ProvenanceError):
            validate_file_line_citation(
                self.workspace, f'{self.source_rel}:2 "wrong excerpt"'
            )

    def test_excerpt_match_passes(self) -> None:
        validate_file_line_citation(
            self.workspace, f'{self.source_rel}:2 "beta line"'
        )

    def test_markdown_optional_allows_missing_citations(self) -> None:
        validate_markdown_provenance(
            self.workspace, "# Summary\nNo citations here.\n", "optional"
        )

    def test_markdown_required_rejects_missing_citations(self) -> None:
        with self.assertRaises(ProvenanceError):
            validate_markdown_provenance(
                self.workspace, "# Summary\nNo citations here.\n", "required"
            )

    def test_markdown_required_accepts_valid_citation(self) -> None:
        text = f"- cite: {self.source_rel}:1\n"
        validate_markdown_provenance(self.workspace, text, "required")

    def test_json_optional_allows_missing_citations(self) -> None:
        validate_json_provenance(self.workspace, {"status": "ok"}, "optional")

    def test_json_required_rejects_missing_citations(self) -> None:
        with self.assertRaises(ProvenanceError):
            validate_json_provenance(self.workspace, {"status": "ok"}, "required")

    def test_json_required_accepts_valid_citations(self) -> None:
        document = {
            "citations": [{"ref": f"{self.source_rel}:1"}],
            "status": "ok",
        }
        validate_json_provenance(self.workspace, document, "required")

    def test_artifact_heading_citation(self) -> None:
        artifact_rel = ".ralph-workspace/artifacts/ns/architecture.md"
        artifact_abs = os.path.join(self.workspace, artifact_rel)
        os.makedirs(os.path.dirname(artifact_abs), exist_ok=True)
        with open(artifact_abs, "w", encoding="utf-8") as handle:
            handle.write("## Module boundaries\nDetails\n")
        validate_artifact_citation(
            self.workspace, f"{artifact_rel}#Module-boundaries"
        )

    def test_artifact_json_pointer_citation(self) -> None:
        artifact_rel = ".ralph-workspace/artifacts/ns/data.json"
        artifact_abs = os.path.join(self.workspace, artifact_rel)
        os.makedirs(os.path.dirname(artifact_abs), exist_ok=True)
        with open(artifact_abs, "w", encoding="utf-8") as handle:
            json.dump({"findings": [{"id": "f1"}]}, handle)
        validate_artifact_citation(
            self.workspace, f"{artifact_rel}#/findings/0"
        )


class ProvenanceStageVerificationTests(unittest.TestCase):
    def test_verify_stage_skips_none_and_validates_required(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            source_rel = "src/example.py"
            source_path = workspace / source_rel
            source_path.parent.mkdir(parents=True)
            source_path.write_text("line one\n", encoding="utf-8")

            artifact_rel = ".ralph-workspace/artifacts/test-ns/research.md"
            artifact_path = workspace / artifact_rel
            artifact_path.parent.mkdir(parents=True)
            artifact_path.write_text(
                f"- cite: {source_rel}:1\n",
                encoding="utf-8",
            )

            stage = {
                "id": "research",
                "artifacts": [
                    {
                        "path": ".ralph-workspace/artifacts/test-ns/research.md",
                        "provenance": "required",
                    },
                    {
                        "path": ".ralph-workspace/artifacts/test-ns/skipped.md",
                        "provenance": "none",
                    },
                ],
            }
            verify_stage_artifact_provenance(
                str(workspace),
                stage,
                stage_id="research",
                artifact_ns="test-ns",
                plan_key="test-ns",
            )

            artifact_path.write_text("No citations\n", encoding="utf-8")
            with self.assertRaises(ProvenanceError):
                verify_stage_artifact_provenance(
                    str(workspace),
                    stage,
                    stage_id="research",
                    artifact_ns="test-ns",
                    plan_key="test-ns",
                )

    def test_validate_artifact_provenance_file_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            source_rel = "src/example.py"
            source_path = workspace / source_rel
            source_path.parent.mkdir(parents=True)
            source_path.write_text("alpha\n", encoding="utf-8")

            artifact_rel = ".ralph-workspace/artifacts/test-ns/review.json"
            artifact_path = workspace / artifact_rel
            artifact_path.parent.mkdir(parents=True)
            with open(artifact_path, "w", encoding="utf-8") as handle:
                json.dump(
                    {"citations": [{"ref": f"{source_rel}:1", "excerpt": "alpha"}]},
                    handle,
                )
            validate_artifact_provenance_file(
                str(workspace), artifact_rel, "required"
            )


if __name__ == "__main__":
    unittest.main()
