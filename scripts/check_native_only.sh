#!/usr/bin/env bash
# Reject cross-platform and hybrid framework material from implementation paths.
set -euo pipefail

cd "$(dirname "$0")/.."

scan_roots=(ShotDeck ShotDeckUITests ShotDeck.xcodeproj Packages scripts)
for manifest in package.json pubspec.yaml settings.gradle settings.gradle.kts build.gradle build.gradle.kts; do
  [ -e "$manifest" ] && scan_roots+=("$manifest")
done

patterns=(
  'flutter'
  'react-native'
  'react_native'
  'expo'
  'kotlin[[:space:]-]*multiplatform'
  'maui'
  'unity'
)

violations=""
for root in "${scan_roots[@]}"; do
  [ -e "$root" ] || continue
  for pattern in "${patterns[@]}"; do
    hits=$(grep -RniE \
      --exclude-dir=.git \
      --exclude-dir=.build \
      --exclude-dir=.swiftpm \
      --exclude='check_native_only.sh' \
      --exclude='*.md' \
      "$pattern" "$root" 2>/dev/null || true)
    [ -n "$hits" ] && violations+="$hits"$'\n'
  done
done

for forbidden_path in android ios/Runner unityLibrary; do
  if [ -e "$forbidden_path" ]; then
    violations+="forbidden path: $forbidden_path"$'\n'
  fi
done

if [ -n "$violations" ]; then
  echo "NATIVE-ONLY GATE FAILED — forbidden framework material found:"
  printf '%s' "$violations"
  exit 1
fi

echo "Native-only framework gate: PASS"
