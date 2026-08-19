# Security Policy

Serein can execute commands and move files through a remote approval path. Treat
it as security-sensitive infrastructure, not as a normal terminal viewer.

## Reporting a vulnerability

Please do not open a public issue for an unpatched vulnerability. Use a private
GitHub security advisory when available, or contact the maintainer privately
with:

- affected version and deployment mode;
- reproduction steps or a minimal proof of concept;
- impact and any required configuration;
- suggested mitigation, if known.

Do not include real tokens, private keys, source code, or personal logs in a
report.

## Deployment guidance

- Set `SEREIN_ENV=production` and use non-default `SEREIN_HOOK_TOKEN` and
  `SEREIN_PAIR_CODE` values.
- Put the backend behind HTTPS and do not expose the development mode.
- Revoke devices and rotate tokens when a device or host is lost.
- Review the approval policy before allowing remote command execution.

Serein is experimental. A passing test suite does not replace a security
review of your deployment and network boundary.
