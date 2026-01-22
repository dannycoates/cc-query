#!/usr/bin/env bash
# Bump version, commit, tag, and push
# Usage: ./scripts/bump.sh [major|minor|patch]

set -euo pipefail

bump_type="${1:-patch}"

# Ensure we're on main branch
branch=$(git branch --show-current)
if [[ "$branch" != "main" ]]; then
    echo "Error: must be on main branch (currently on '$branch')"
    exit 1
fi

# Get current version from plugin.json
current=$(jq -r .version .claude-plugin/plugin.json)

# Parse semver
IFS='.' read -r major minor patch <<< "$current"

# Increment based on bump type
case "$bump_type" in
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    patch)
        patch=$((patch + 1))
        ;;
    *)
        echo "Invalid bump type: $bump_type (use major, minor, or patch)"
        exit 1
        ;;
esac

new_version="${major}.${minor}.${patch}"
echo "Bumping version: $current -> $new_version"

# Update all version files
jq --arg v "$new_version" '.version = $v' .claude-plugin/plugin.json > .claude-plugin/plugin.json.tmp
mv .claude-plugin/plugin.json.tmp .claude-plugin/plugin.json

jq --arg v "$new_version" '.plugins[0].version = $v' .claude-plugin/marketplace.json > .claude-plugin/marketplace.json.tmp
mv .claude-plugin/marketplace.json.tmp .claude-plugin/marketplace.json

jq --arg v "$new_version" '.version = $v' package.json > package.json.tmp
mv package.json.tmp package.json

# Commit, tag, and push
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json package.json
git commit -m "v${new_version}"
git tag "v${new_version}"
git push && git push --tags

echo "Released v${new_version}"
