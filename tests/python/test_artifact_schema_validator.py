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
    artifact_name_from_path,
    build_stage_contract,
    resolve_artifact_abs_path,
    validate_artifact_text,
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

    def test_schema_valued_additional_properties_validates_dynamic_keys(self) -> None:
        schema = {
            "type": "object",
            "additionalProperties": {"type": "array", "items": {"type": "integer"}},
        }
        validate_instance({"lane-a": [0, 2]}, schema)
        with self.assertRaises(SchemaValidationError) as ctx:
            validate_instance({"lane-a": ["wrong"]}, schema)
        self.assertEqual(ctx.exception.json_path, "$/lane-a/0")

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

    def test_string_length_bounds(self) -> None:
        schema = {"type": "string", "minLength": 2, "maxLength": 4}
        validate_instance("okay", schema)
        with self.assertRaises(SchemaValidationError):
            validate_instance("x", schema)
        with self.assertRaises(SchemaValidationError):
            validate_instance("excess", schema)


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
        # "feedback" is optional now, so an omitted key is valid; use an enum
        # violation to keep exercising schema-failure location reporting.
        artifact_path.write_text(json.dumps({"status": "maybe"}), encoding="utf-8")
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


# Bundled schemas that assert_supported_schema does not govern. That helper
# validates operator-authored stage artifact-output schemas (finalOutputSchema),
# whose only callers are planner_contract, router_contract, and rubric_contract.
# Config schemas and multi-record containers live in the same directory but are
# consumed by their own normalizers, so they are checked for their own shape.
NON_ARTIFACT_SCHEMAS = {
    # Killswitch config schema, consumed by killswitch_config.py. Carries the
    # standard "$schema" annotation, which the artifact validator does not take.
    "killswitch.schema.json",
    # Container of the three workflow action record shapes, not one document.
    "workflow-action.schema.json",
}

# Container schemas and the sub-schema keys each one holds.
CONTAINER_SCHEMA_KEYS = {
    "workflow-action.schema.json": ("request", "decision", "consumed"),
}


class BundledArtifactSchemaTests(unittest.TestCase):
    def test_bundled_schemas_are_supported_documents(self) -> None:
        schema_dir = REPO_ROOT / "bundle/.ralph/schemas"
        seen = 0
        for schema_path in sorted(schema_dir.glob("*.schema.json")):
            if schema_path.name in NON_ARTIFACT_SCHEMAS:
                continue
            with self.subTest(schema=schema_path.name):
                document = load_schema_document(str(schema_path))
                assert_supported_schema(document)
                seen += 1
        # Guard against the exclusion set silently swallowing the whole glob.
        self.assertGreater(seen, 0)

    def test_container_schemas_hold_supported_sub_schemas(self) -> None:
        schema_dir = REPO_ROOT / "bundle/.ralph/schemas"
        for name, keys in CONTAINER_SCHEMA_KEYS.items():
            document = load_schema_document(str(schema_dir / name))
            self.assertEqual(tuple(document.keys()), keys)
            for key in keys:
                with self.subTest(schema=name, sub_schema=key):
                    assert_supported_schema(document[key])

    def test_excluded_schemas_still_exist_and_parse(self) -> None:
        schema_dir = REPO_ROOT / "bundle/.ralph/schemas"
        for name in sorted(NON_ARTIFACT_SCHEMAS):
            with self.subTest(schema=name):
                self.assertIsInstance(load_schema_document(str(schema_dir / name)), dict)


TRADE_INTENT_SCHEMA = {
    "type": "object",
    "required": ["generatedAt", "intents"],
    "additionalProperties": False,
    "properties": {
        "generatedAt": {"type": "string", "minLength": 1},
        "intents": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["symbol", "thesis"],
                "additionalProperties": False,
                "properties": {
                    "symbol": {"type": "string", "minLength": 1},
                    "thesis": {"type": "string", "minLength": 1},
                },
            },
        },
    },
}


class ValidateArtifactTextTests(unittest.TestCase):
    """The pre-write gate behind ralph_write_artifact."""

    def _schema_file(self, tmp: str, schema: dict) -> str:
        path = os.path.join(tmp, "s.schema.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(schema, handle)
        return path

    def test_accepts_conforming_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            schema = self._schema_file(tmp, TRADE_INTENT_SCHEMA)
            validate_artifact_text(
                json.dumps({"generatedAt": "2026-01-01T00:00:00Z",
                            "intents": [{"symbol": "NVDA", "thesis": "up"}]}),
                schema,
            )

    def test_reports_location_of_missing_required_property(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            schema = self._schema_file(tmp, TRADE_INTENT_SCHEMA)
            with self.assertRaises(ValueError) as ctx:
                validate_artifact_text(
                    json.dumps({"generatedAt": "x",
                                "intents": [{"symbol": "NVDA", "thesis": "ok"},
                                            {"symbol": "AMD"}]}),
                    schema,
                )
            message = str(ctx.exception)
            self.assertIn("location=$/intents/1", message)
            self.assertIn("thesis", message)

    def test_rejects_unknown_property(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            schema = self._schema_file(tmp, TRADE_INTENT_SCHEMA)
            with self.assertRaises(ValueError) as ctx:
                validate_artifact_text(
                    json.dumps({"generatedAt": "x", "intents": [], "extra": 1}), schema
                )
            self.assertIn("location=$/extra", str(ctx.exception))

    def test_rejects_empty_content(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            schema = self._schema_file(tmp, TRADE_INTENT_SCHEMA)
            with self.assertRaises(ValueError):
                validate_artifact_text("   ", schema)

    def test_malformed_json_is_a_value_error_not_a_crash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            schema = self._schema_file(tmp, TRADE_INTENT_SCHEMA)
            with self.assertRaises(ValueError) as ctx:
                validate_artifact_text('{"generatedAt": ', schema)
            self.assertIn("not valid JSON", str(ctx.exception))

    def test_unsupported_schema_keyword_surfaces_as_value_error(self) -> None:
        # assert_supported_schema raises UnsupportedSchemaKeywordError, which is
        # not a ValueError; the wrapper must convert it rather than let it escape.
        with tempfile.TemporaryDirectory() as tmp:
            schema = self._schema_file(
                tmp, {"$schema": "https://json-schema.org/draft-07/schema#", "type": "object"}
            )
            with self.assertRaises(ValueError) as ctx:
                validate_artifact_text("{}", schema)
            self.assertIn("$schema", str(ctx.exception))


class StageContractTests(unittest.TestCase):
    """The contract the orchestrator publishes for the artifact MCP tools."""

    def test_derives_name_from_filename_stem(self) -> None:
        self.assertEqual(artifact_name_from_path("a/b/trade-intents.json"), "trade-intents")
        self.assertEqual(artifact_name_from_path("a/b/quant-notes.md"), "quant-notes")
        self.assertEqual(artifact_name_from_path("a/b/notes"), "notes")

    def test_expands_tokens_so_no_placeholder_reaches_the_agent(self) -> None:
        stage = {
            "artifacts": [{"path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.json"}],
            "inputArtifacts": [{"path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/in.md"}],
        }
        contract = build_stage_contract(stage, stage_id="analyze", artifact_ns="ns-1")
        self.assertEqual(contract["artifactNs"], "ns-1")
        rendered = json.dumps(contract)
        self.assertNotIn("{{", rendered)
        self.assertEqual(contract["produces"][0]["name"], "out")
        self.assertEqual(contract["requires"][0]["name"], "in")

    def test_marks_json_and_text_artifacts(self) -> None:
        stage = {"artifacts": [{"path": "a/out.json"}, {"path": "a/notes.md"}]}
        contract = build_stage_contract(stage, stage_id="s")
        formats = {e["name"]: e["format"] for e in contract["produces"]}
        self.assertEqual(formats, {"out": "json", "notes": "text"})

    def test_dedupes_artifacts_and_outputArtifacts(self) -> None:
        entry = {"path": "a/out.json", "required": True}
        stage = {"artifacts": [entry], "outputArtifacts": [entry]}
        contract = build_stage_contract(stage, stage_id="s")
        self.assertEqual(len(contract["produces"]), 1)

    def test_duplicate_names_are_an_authoring_error(self) -> None:
        stage = {"artifacts": [{"path": "a/notes.md"}, {"path": "b/notes.md"}]}
        with self.assertRaises(ValueError) as ctx:
            build_stage_contract(stage, stage_id="s")
        self.assertIn("duplicate artifact name", str(ctx.exception))

    def test_explicit_name_resolves_a_collision(self) -> None:
        stage = {"artifacts": [{"path": "a/notes.md", "name": "quant-notes"},
                               {"path": "b/notes.md"}]}
        contract = build_stage_contract(stage, stage_id="s")
        self.assertEqual([e["name"] for e in contract["produces"]], ["quant-notes", "notes"])

    def test_resolved_path_follows_state_root_for_workspace_artifacts(self) -> None:
        # The orchestrator and the MCP server disagree about what
        # RALPH_PLAN_WORKSPACE_ROOT means, so the contract resolves paths once.
        self.assertEqual(
            resolve_artifact_abs_path(
                ".ralph-workspace/artifacts/ns/out.json",
                workspace="/repo",
                state_root="/state/.ralph-workspace",
            ),
            "/state/.ralph-workspace/artifacts/ns/out.json",
        )

    def test_resolved_path_falls_back_to_workspace(self) -> None:
        self.assertEqual(
            resolve_artifact_abs_path("ralph/schemas/x.json", workspace="/repo", state_root=""),
            "/repo/ralph/schemas/x.json",
        )

    def test_contract_carries_resolved_path_when_workspace_given(self) -> None:
        stage = {"artifacts": [{"path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/out.json"}]}
        contract = build_stage_contract(
            stage, stage_id="s", artifact_ns="ns",
            workspace="/repo", state_root="/repo/.ralph-workspace",
        )
        self.assertEqual(
            contract["produces"][0]["resolvedPath"],
            "/repo/.ralph-workspace/artifacts/ns/out.json",
        )

if __name__ == "__main__":
    unittest.main()
