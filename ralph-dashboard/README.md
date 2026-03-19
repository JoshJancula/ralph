# Ralph dashboard

## Testing

Install the local dashboard package from the `ralph-dashboard/` directory before running tests:

```bash
cd ralph-dashboard
python3 -m pip install -e ".[dev]"
python3 -m pytest --collect-only
```

These commands use Python 3.10+ per the repository guidance and verify that the tooling is wired up even when no tests exist yet.

To keep the dashboard gate honest, enforce line coverage on the `ralph_dashboard` package every time tests run:

```bash
cd ralph-dashboard
python3 -m pytest tests/ -v --cov=ralph_dashboard --cov-report=term-missing --cov-report=html --cov-fail-under=80
```

This fails if line coverage drops below 80% and produces `ralph-dashboard/htmlcov/index.html` for reviewers.
