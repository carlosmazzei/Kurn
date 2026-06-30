# Security Policy

Kurn is a local-first iOS and watchOS app that handles sensitive user data on
device: meeting audio, transcripts, summaries, and API keys for third-party
providers (OpenAI, Anthropic, Google AI, Groq). We take security and privacy
seriously and welcome responsible disclosure of vulnerabilities.

## Supported Versions

Security fixes are applied to the latest released version on the `main`
branch. Older releases are not patched separately.

| Version            | Supported          |
| ------------------ | ------------------ |
| `main` (latest)    | :white_check_mark: |
| Older tagged releases | :x:             |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Report vulnerabilities privately through GitHub's
[Private Vulnerability Reporting][pvr]:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** (or use the direct link:
   <https://github.com/carlosmazzei/Kurn/security/advisories/new>).
3. Fill in the form with as much detail as you can — see "What to include"
   below.

[pvr]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

### What to include

A useful report typically contains:

- A clear description of the vulnerability and its impact.
- The affected component (e.g. `KeychainManager`, `AudioRecorderService`,
  Live Activity deep link handler, a specific `LLMProvider` implementation).
- Steps to reproduce, including device/OS/Xcode version when relevant.
- A proof of concept if you have one.
- Any suggested mitigation, if you have ideas.
- Whether you would like to be credited and, if so, how.

### What to expect

- **Acknowledgement** of your report within **5 business days**.
- An initial **assessment** (severity, scope, reproducibility) within
  **10 business days**.
- Coordinated remediation: we will keep you informed of progress, agree on a
  disclosure timeline with you, and credit you in the security advisory unless
  you prefer to remain anonymous.

We aim to ship fixes for high-severity issues as quickly as the platform
release process allows.

## Scope

In scope:

- The Kurn iOS app, the Apple Watch companion (`KurnWatch`), and the
  `KurnLiveActivityExtension`.
- Code in this repository, including build configuration, CI workflows
  (`.github/workflows/`), and any helper scripts.
- Handling of secrets (API keys in the Keychain), local data at rest
  (SwiftData store and `.m4a` files in the protected
  `Documents/Recordings/` subdirectory, encrypted via iOS Data Protection
  and gated behind device authentication by default), and network requests
  to user-configured LLM and transcription providers.

Out of scope:

- Vulnerabilities in third-party services and SDKs we depend on (OpenAI,
  Anthropic, Google AI, Groq, FluidAudio, Apple frameworks). Please report
  those upstream — though we appreciate a heads-up if it materially affects
  Kurn users.
- Issues that require an attacker to already have physical access to an
  unlocked device.
- Social-engineering or phishing reports that do not involve a defect in
  Kurn itself.
- Reports generated purely by automated scanners without a demonstrated,
  reproducible impact on Kurn.

## Safe Harbor

We will not pursue or support any legal action against researchers who:

- Make a good-faith effort to comply with this policy.
- Avoid privacy violations, destruction of data, and interruption or
  degradation of any service.
- Only interact with accounts they own or have explicit permission to access.
- Give us a reasonable opportunity to remediate before any public disclosure.

Thank you for helping keep Kurn and its users safe.
