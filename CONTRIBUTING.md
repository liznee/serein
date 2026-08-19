# Contributing

Issues and pull requests are welcome. Serein is an experimental project, so
small, focused changes are easier to review than broad rewrites.

Before opening a pull request:

1. Explain the user problem and the intended behavior.
2. Add or update tests for behavior changes.
3. Run the relevant checks:

   ```text
   cd backend && go test ./... && go vet ./...
   cd agent && python -m pytest -q && npm test
   cd hooks && python -m unittest discover -s . -p 'test_*.py' -q
   ```

4. Do not include tokens, logs, databases, build artifacts, private paths, or
   generated signing files.
5. For security-sensitive changes, explain the threat model and failure mode.

Please keep compatibility with self-hosted deployments in mind. Changes to
the HTTP API, pairing format, hook decisions, or environment variables should
include migration notes.
