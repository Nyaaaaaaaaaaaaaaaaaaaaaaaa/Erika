"""Select CI checks from the complete push or pull-request change set."""

import json
import os
from pathlib import Path
import subprocess


PLATFORMS = ("android", "ios", "macos", "tvos", "windows", "ohos")
FLAGS = ("native", "package", *PLATFORMS, "artifacts")
PACKAGE = "packages/erika_flutter/"
NATIVE_PREFIXES = (
    ".cargo/", "crates/", "xtask/", "third_party/patches/",
    "third_party/wgpu-hal/",
)
ARTIFACT_SCRIPTS = {
    ".github/scripts/check_native_artifacts.py",
    ".github/scripts/test_native_artifacts.py",
}


def classify(paths, *, all_checks=False):
    """Return booleans; native-only edits do not add Flutter consumer runs."""
    selected = dict.fromkeys(FLAGS, all_checks)
    for path in paths:
        if (path.startswith(".github/actions/")
                or path == ".github/workflows/ci-changes.yml"
                or (path.startswith(".github/scripts/")
                    and path not in ARTIFACT_SCRIPTS)):
            selected.update(dict.fromkeys(FLAGS, True))
        if (path.startswith(NATIVE_PREFIXES)
                or path in ("Cargo.toml", "Cargo.lock", ".github/workflows/ci.yml")
                or path.startswith("rust-toolchain")):
            selected["native"] = True
            selected.update(dict.fromkeys(PLATFORMS, True))
        if path in ARTIFACT_SCRIPTS:
            selected["package"] = selected["artifacts"] = True
        if path == ".github/workflows/flutter-package.yml":
            selected["package"] = selected["artifacts"] = True
            selected.update(dict.fromkeys(PLATFORMS, True))
        for platform in PLATFORMS:
            if path == f".github/workflows/{platform}.yml":
                selected[platform] = True
        if path.startswith("packages/erika_ohos/"):
            selected["ohos"] = True
        if not path.startswith(PACKAGE):
            continue
        selected["package"] = True
        relative = path[len(PACKAGE):]
        if relative == "native_artifacts.properties":
            selected["artifacts"] = True
        elif relative == "native/prepare_apple_prebuilt.sh":
            selected.update(dict.fromkeys(("ios", "macos", "tvos"), True))
        elif (relative == "pubspec.yaml"
              or relative.startswith(("native/", "tool/"))):
            selected.update(dict.fromkeys(PLATFORMS, True))
        else:
            for platform in PLATFORMS:
                if relative.startswith(platform + "/"):
                    selected[platform] = True
    return selected


def changed_paths(event_name, event, *, cwd=None):
    """None means a full run, including missing history and initial pushes."""
    if event_name == "workflow_dispatch":
        return None
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
        separator = "..."
    elif event_name == "push":
        base, head = event.get("before"), event.get("after")
        separator = ".."
    else:
        return None
    if not base or not head or set(base) == {"0"}:
        return None
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z",
             f"{base}{separator}{head}", "--"],
            cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError:
        print("Unable to compare Git history; selecting all checks.")
        return None
    return result.stdout.decode("utf-8", errors="surrogateescape").rstrip("\0").split("\0") if result.stdout else []


def outputs(selected):
    result = {key: str(value).lower() for key, value in selected.items()}
    result["apple"] = json.dumps(
        [platform for platform in ("ios", "macos") if selected[platform]],
        separators=(",", ":"),
    )
    return result


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    paths = changed_paths(os.environ["GITHUB_EVENT_NAME"], event)
    result = outputs(classify(paths or [], all_checks=paths is None))
    print(json.dumps(result, sort_keys=True))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in result.items():
            output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
