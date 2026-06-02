# Security Policy

## Reporting Vulnerabilities

Please use GitHub Security Advisories for private vulnerability reports. Do not
open public issues that include API keys, bearer tokens, signing keys, customer
data, or other secrets.

## Secret Handling

This repository is intended to be public. Do not commit:

- Logister project API keys
- Apple signing certificates, provisioning profiles, or App Store Connect keys
- Cloudflare, GitHub, Google Play, or other service tokens
- `.env`, `.p8`, `.p12`, `.pem`, `.key`, or machine-specific configuration files

Runtime credentials should be supplied by the app that installs the SDK. Swift
Package Manager distribution from a public repository does not require a package
registry secret.

No release secrets are required for the current CI-only workflow. If a future
workflow needs App Store Connect or signing credentials, set them as GitHub
Actions secrets with the GitHub CLI and reference them only from workflow
environment variables:

```bash
gh secret set APP_STORE_CONNECT_KEY_ID --repo taimoorq/logister-ios
gh secret set APP_STORE_CONNECT_ISSUER_ID --repo taimoorq/logister-ios
gh secret set APP_STORE_CONNECT_PRIVATE_KEY --repo taimoorq/logister-ios < AuthKey_PRIVATE.p8
```
