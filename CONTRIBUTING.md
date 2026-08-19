# Contributing

## Feedback first

Serein is currently in a feedback-only phase. Please open an **Issue** for:

- bugs, crashes or unexpected behaviour;
- feature requests and usability feedback;
- security concerns (see `SECURITY.md` for the preferred channel).

## Pull requests

External pull requests are **not being merged for now** while the project
stabilises. Do not open a pull request expecting it to be accepted; if you have
a concrete fix, describe it in an Issue with a minimal reproduction or patch
sketch, and it will be considered once maintainers open contributions.

If you want to experiment, feel free to fork the repository.

## Reporting guidelines

1. Explain the observed behaviour and what you expected.
2. Include the Serein version, HarmonyOS version and backend version when
   relevant.
3. Never include tokens, logs with credentials, databases, build artifacts,
   private paths or generated signing files.
4. For security-sensitive reports, describe the threat model and failure mode.

Please keep compatibility with self-hosted deployments in mind. Changes to
the HTTP API, pairing format, hook decisions, or environment variables should
include migration notes.
