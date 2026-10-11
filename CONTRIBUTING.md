# Contributing

Thanks for helping improve Productivity OS.

For bugs, include the command, macOS/CPU architecture, reproduction steps, expected result, and actual error. Keep screenshots and logs free of personal data. Discuss larger changes in an issue before implementing them.

Follow [development setup and validation](docs/development.md). Keep changes focused, update the relevant guide, and describe checks performed and their limits in your pull request. Use disposable test data. Do not commit compiled helpers, secrets, private paths, runtime databases, or signing identities.

Preserve user control: no automatic quitting of other apps, no deletion of unsaved captures, and no silent relaxation of protected focus rules. Changes to privileged helpers need tests for validation and preservation of unrelated state.

Contributions are provided under the repository's MIT license. Preserve third-party attribution.
