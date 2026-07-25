import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "bundle" / ".ralph" / "python"))

from artifact_json_schema import (  # noqa: E402
    SchemaValidationError,
    UnsupportedSchemaKeywordError,
    assert_supported_schema,
    expand_artifact_tokens,
    extract_json_object_text,
    iter_orchestration_final_output_schema_entries,
    iter_orchestration_schema_entries,
    load_schema_document,
    resolve_project_path,
    resolve_schema_file,
    validate_final_output,
    validate_instance,
    validate_json_text,
    validate_orchestration_schema_paths,
    validate_portable_path,
    verify_stage_artifact_schemas,
)


class ArtifactSchemaPathTests(unittest.TestCase):
    def test_rejects_absolute_schema_paths(self) -> None:
        with self.assertRaises(ValueError):
            validate_portable_path("schema path", "/tmp/schema.json")

    def test_rejects_traversal_schema_paths(self) -> None:
        with self.assertRaises(ValueError):
            validate_portable_path("schema path", "../secrets/schema.json")

    def test_rejects_env_like_schema_paths(self) -> None:
        with self.assertRaises(ValueError):
            validate_portable_path("schema path", ".ralph/.env.local")

    def test_expands_artifact_namespace_tokens(self) -> None:
        expanded = expand_artifact_tokens(
            ".ralph/schemas/{{ARTIFACT_NS}}/verdict.schema.json",
            artifact_ns="feature-a",
            plan_key="feature-a",
            stage_id="review",
        )
        self.assertEqual(expanded, ".ralph/schemas/feature-a/verdict.schema.json")

    def test_resolve_schema_file_stays_inside_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            schema_rel = "schemas/verdict.schema.json"
            schema_path = workspace / schema_rel
            schema_path.parent.mkdir(parents=True)
            schema_path.write_text('{"type":"object"}', encoding="utf-8")
            resolved = resolve_schema_file(str(workspace), schema_rel)
            self.assertEqual(os.path.realpath(resolved), os.path.realpath(schema_path))

    def test_resolve_schema_file_rejects_outside_project_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            outside = workspace.parent / "outside.schema.json"
            outside.write_text("{}", encoding="utf-8")
            rel = os.path.relpath(outside, workspace)
            with self.assertRaises(ValueError):
                resolve_project_path(str(workspace), rel)


class ArtifactSchemaDocumentTests(unittest.TestCase):
    def test_rejects_unsupported_schema_keyword(self) -> None:
        with self.assertRaises(UnsupportedSchemaKeywordError) as ctx:
            assert_supported_schema({"type": "object", "$ref": "#/definitions/x"})
        self.assertEqual(ctx.exception.keyword, "$ref")

    def test_valid_object_passes(self) -> None:
        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["status"],
            "properties": {
                "status": {"type": "string", "enum": ["approved", "changes-required"]},
                "feedback": {"type": "array", "items": {"type": "string"}},
            },
        }
        validate_json_text(
            json.dumps({"status": "approved", "feedback": []}),
            schema,
        )

    def test_missing_required_field_fails_with_location(self) -> None:
        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["status", "feedback"],
            "properties": {
                "status": {"type": "string"},
                "feedback": {"type": "array", "items": {"type": "string"}},
            },
        }
        with self.assertRaises(SchemaValidationError) as ctx:
            validate_json_text(json.dumps({"status": "approved"}), schema)
        self.assertEqual(ctx.exception.json_path, "$")
        self.assertIn("feedback", ctx.exception.message)

    def test_additional_properties_false_rejects_unknown_keys(self) -> None:
        schema = {
            "type": "object",
            "additionalProperties": False,
            "properties": {"status": {"type": "string"}},
        }
        with self.assertRaises(SchemaValidationError) as ctx:
            validate_json_text(json.dumps({"status": "ok", "extra": 1}), schema)
        self.assertEqual(ctx.exception.json_path, "$/extra")

    def test_malformed_json_fails(self) -> None:
        schema = {"type": "object"}
        with self.assertRaises(SchemaValidationError) as ctx:
            validate_json_text("{not-json", schema)
        self.assertEqual(ctx.exception.json_path, "$")

    def test_pattern_minimum_maximum_and_array_bounds(self) -> None:
        schema = {
            "type": "object",
            "properties": {
                "id": {"type": "string", "pattern": "^[a-z]+$"},
                "score": {"type": "number", "minimum": 0, "maximum": 1},
                "tags": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 2,
                    "items": {"type": "string"},
                },
            },
        }
        validate_instance(
            {"id": "abc", "score": 0.5, "tags": ["one"]},
            schema,
        )
        with self.assertRaises(SchemaValidationError):
            validate_instance({"id": "ABC", "score": 0.5, "tags": ["one"]}, schema)


class ArtifactSchemaOrchestrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self.tmp.name)
        self.schema_path = self.workspace / "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        self.schema_path.parent.mkdir(parents=True, exist_ok=True)
        self.schema_path.write_text(
            (REPO_ROOT / "bundle/.ralph/schemas/evaluator-verdict.schema.json").read_text(
                encoding="utf-8"
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_validate_orchestration_schema_paths_requires_existing_schema_file(self) -> None:
        orchestration = {
            "namespace": "demo",
            "stages": [
                {
                    "id": "review",
                    "artifacts": [
                        {
                            "path": ".ralph-workspace/artifacts/demo/review.json",
                            "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json",
                        }
                    ],
                }
            ],
        }
        validate_orchestration_schema_paths(
            str(self.workspace),
            orchestration,
            artifact_ns="demo",
        )

    def test_validate_orchestration_schema_paths_rejects_missing_schema_file(self) -> None:
        orchestration = {
            "namespace": "demo",
            "stages": [
                {
                    "id": "review",
                    "artifacts": [
                        {
                            "path": ".ralph-workspace/artifacts/demo/review.json",
                            "schema": "bundle/.ralph/schemas/missing.schema.json",
                        }
                    ],
                }
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            validate_orchestration_schema_paths(
                str(self.workspace),
                orchestration,
                artifact_ns="demo",
            )
        self.assertIn("schema file not found", str(ctx.exception))

    def test_verify_stage_artifact_schemas_accepts_valid_json(self) -> None:
        artifact_rel = ".ralph-workspace/artifacts/demo/review.json"
        artifact_path = self.workspace / artifact_rel
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        artifact_path.write_text(
            json.dumps({"status": "approved", "feedback": []}),
            encoding="utf-8",
        )
        stage = {
            "id": "review",
            "artifacts": [
                {
                    "path": artifact_rel,
                    "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json",
                }
            ],
        }
        verify_stage_artifact_schemas(
            str(self.workspace),
            stage,
            stage_id="review",
            artifact_ns="demo",
        )

    def test_verify_stage_artifact_schemas_reports_location_on_failure(self) -> None:
        artifact_rel = ".ralph-workspace/artifacts/demo/review.json"
        artifact_path = self.workspace / artifact_rel
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        artifact_path.write_text(json.dumps({"status": "approved"}), encoding="utf-8")
        stage = {
            "id": "review",
            "artifacts": [
                {
                    "path": artifact_rel,
                    "schema": "bundle/.ralph/schemas/evaluator-verdict.schema.json",
                }
            ],
        }
        with self.assertRaises(ValueError) as ctx:
            verify_stage_artifact_schemas(
                str(self.workspace),
                stage,
                stage_id="review",
                artifact_ns="demo",
            )
        message = str(ctx.exception)
        self.assertIn("stage=review", message)
        self.assertIn(f"artifact={artifact_rel}", message)
        self.assertIn("schema=bundle/.ralph/schemas/evaluator-verdict.schema.json", message)
        self.assertIn("location=", message)

    def test_iter_orchestration_schema_entries_accepts_input_and_output_artifacts(self) -> None:
        orchestration = {
            "stages": [
                {
                    "id": "one",
                    "inputArtifacts": [{"path": "in.json", "schema": "schemas/in.schema.json"}],
                    "outputArtifacts": [{"path": "out.json", "schema": "schemas/out.schema.json"}],
                }
            ]
        }
        entries = iter_orchestration_schema_entries(orchestration)
        self.assertEqual(len(entries), 2)

    def test_extract_json_object_text_prefers_fenced_block(self) -> None:
        text = 'prose\n```json\n{"status":"approved"}\n```\n'
        extracted = extract_json_object_text(text)
        self.assertEqual(extracted, '{"status":"approved"}')

    def test_validate_final_output_accepts_matching_artifact(self) -> None:
        schema_path = REPO_ROOT / "bundle/.ralph/schemas/evaluator-verdict.schema.json"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(json.dumps({"status": "approved", "feedback": []}))
            artifact_path = handle.name
        try:
            validate_final_output(
                str(schema_path),
                text="not json",
                artifact_paths=[artifact_path],
            )
        finally:
            os.unlink(artifact_path)

    def test_validate_orchestration_schema_paths_checks_final_output_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            schema_rel = "schemas/custom.schema.json"
            schema_path = workspace / schema_rel
            schema_path.parent.mkdir(parents=True)
            schema_path.write_text('{"type":"object"}', encoding="utf-8")
            orchestration = {
                "namespace": "demo",
                "stages": [
                    {
                        "id": "review",
                        "finalOutputSchema": schema_rel,
                    }
                ],
            }
            validate_orchestration_schema_paths(str(workspace), orchestration, artifact_ns="demo")


class BundledArtifactSchemaTests(unittest.TestCase):
    def test_bundled_schemas_are_supported_documents(self) -> None:
        schema_dir = REPO_ROOT / "bundle/.ralph/schemas"
        for schema_path in sorted(schema_dir.glob("*.schema.json")):
            with self.subTest(schema=schema_path.name):
                document = load_schema_document(str(schema_path))
                assert_supported_schema(document)


if __name__ == "__main__":
    unittest.main()
