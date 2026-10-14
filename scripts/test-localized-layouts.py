#!/usr/bin/env python3
"""Render real localized SwiftUI controls without changing macOS preferences.

SwiftPM's command-line test host has no app localizations. Wrap its runner in a
temporary app with the production resources so both Text keys and dynamic
strings resolve as they do in the installed app. Each language gets a fresh
process because Foundation caches the selected bundle localization.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--language", action="append", help="Default: all app languages")
    parser.add_argument("--output", type=Path,
                        default=Path(tempfile.gettempdir()) / "almaeng-localized-layouts")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    info = plistlib.loads((root / "Packaging/Info.plist").read_bytes())
    languages = args.language or info["CFBundleLocalizations"]
    if not set(languages) <= set(info["CFBundleLocalizations"]):
        parser.error("--language must be a supported app localization")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    if not args.skip_build:
        subprocess.run(["swift", "build", "--disable-sandbox", "--build-tests"],
                       cwd=root, check=True)
    binary_directory = Path(subprocess.check_output(
        ["swift", "build", "--disable-sandbox", "--show-bin-path"], cwd=root,
        text=True).strip())
    test_bundle = binary_directory / "ImageViewerPackageTests.xctest/Contents/MacOS/ImageViewerPackageTests"
    swift = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
    helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
    platform = Path(subprocess.check_output(
        ["xcrun", "--show-sdk-platform-path"], text=True).strip())
    frameworks = platform / "Developer/Library"
    results = []

    with tempfile.TemporaryDirectory(prefix="almaeng-localized-runner-") as temporary:
        contents = Path(temporary) / "LayoutTests.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        runner = contents / "MacOS/Runner"
        shutil.copy2(helper, runner)
        shutil.copytree(root / "Sources/ImageViewer/Resources", contents / "Resources")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.openimageviewer.LocalizationLayoutTests",
            "CFBundleExecutable": "Runner",
            "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": info["CFBundleDevelopmentRegion"],
            "CFBundleLocalizations": info["CFBundleLocalizations"],
        }))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)],
                       check=True)
        for language in languages:
            env = os.environ.copy()
            env["DYLD_FRAMEWORK_PATH"] = ":".join(str(frameworks / name) for name in
                                                  ("Frameworks", "PrivateFrameworks"))
            env["EXPECTED_APP_LANGUAGE"] = language
            env["IMAGEVIEWER_LOCALIZED_CONTROLS_OUTPUT"] = str(output)
            log = output / f"{language}.log"
            with log.open("w") as stream:
                result = subprocess.run([
                    str(runner), "--test-bundle-path", str(test_bundle),
                    "--testing-library", "swift-testing", "--filter",
                    "LocalizedControlsLayoutTests|LanguageSettingsTests.currentLanguageMatchesUI",
                    "-AppleLanguages", f"({language})",
                ], cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT)
            results.append({"language": language, "passed": result.returncode == 0,
                            "log": str(log)})
            print(f"{language}: {'passed' if result.returncode == 0 else 'FAILED'}", flush=True)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
