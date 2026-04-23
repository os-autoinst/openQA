# openQA Agent Guidelines

Backend: Perl (Mojolicious), Minion job queue, PostgreSQL. Frontend:
JavaScript (Bootstrap).

## Build & Test Commands

- `make tidy`: Must pass before committing (runs `perltidy` +
  `eslint/prettier`).
- `make test-checkstyle`: Must pass before committing.
- `make test-unit-and-integration TESTS=t/your_test.t`: Run specific tests.
- `make test`: Full test suite.

## Conventions

- Commits: [Conventional
  Commits](https://www.conventionalcommits.org/en/v1.0.0/) format. Include
  motivation and details for "feat" commits.
- Documentation: Markdown (`.md`).

## Agent Guidelines

- **Planning:** Only create `.md` plan documents in `tasks/`. Do not change
  other files. Every plan MUST include test adaptations or new tests.
- **Verification:** Every code change must have corresponding test adaptations
  or new tests. `make tidy` and `make test-checkstyle` must pass before
  creating git commits.

## Constraints

- `tasks/`: Read/write access for planning. NEVER run git add, git commit, or
  git rm on this directory or delete files from there.
- Never run git clean or any command that deletes unversioned files. Ask the
  user for confirmation.
- Commit message format: 50/80 rule, 80-char limit, wrap in single quotes.
