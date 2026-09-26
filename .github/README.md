# CI build selection and caches

Ordinary pushes and pull requests retain the lightweight quality checks. Native
compilation and Flutter source consumers are selected from changed files:

| Change | Expensive validation |
| --- | --- |
| Flutter Dart, tests, or package documentation | Package analysis, tests, and isolated-package checks only |
| `native_artifacts.properties` | Package checks plus comparison with the release's `SHA256SUMS` |
| One Flutter platform bridge or build script | That platform's source consumer |
| Shared Apple prebuilt helper | Apple platform validation |
| Shared native source, Cargo configuration, native recipes, or patches | Native platform workflows; mixed Flutter package changes also select the relevant source consumers |
| CI selection/cache infrastructure | Full affected validation |
| Manual CI workflow run | All jobs in that workflow |

The reusable `ci-changes.yml` compares a push's complete before/after range and a
pull request's merge-base/head range. Missing push history falls back to a full
selection. It does not inspect only the last commit. Flutter source consumers
are not newly triggered by native-only commits. The duplicate Flutter-package
tvOS compile is owned by the existing native CI job instead.

Release still builds every published platform and ABI. Its build commands,
symbol checks, archive contents, and publishing gates remain unchanged.

Native caches use the same per-target identity across CI, Flutter, and Release.
They include the host OS/architecture, target, native profile, SDK/API/deployment
descriptor, native recipe, and patches. Only generated directories are cached;
tracked `third_party/wgpu-hal` and patch sources must never be restored from a
build cache. Keep the native build markers as well as `dist`, because the builder
uses those markers to decide whether it can reuse a dependency. Do not add broad
restore prefixes without extending toolchain validation in those markers.

Rust dependency caches are separate from native caches. Release and OHPM use
explicit native cache steps so they can still check out older source tags that
do not contain the shared local action. A new cache key or an inaccessible/expired
branch cache still requires a cold build; identical keys do not bypass GitHub's
branch cache restrictions.

Validate CI edits locally with:

```sh
python -m unittest discover -s .github/scripts -p 'test_*.py'
actionlint -shellcheck= -pyflakes=
git diff --check
```

Actionlint covers workflow syntax and expressions. Local tests cover change
selection and artifact manifest validation; cache hits and cross-platform build
behavior still need an actual Actions run. Compare summed job time separately
from wall-clock completion time.
