#!/usr/bin/env bash
# Copyright (c) 2026, Salesforce, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Publish a built release: push the updates/ folder to the feed repository
# (salesforce-misc/thread), tag it, and create the matching GitHub Release.
#
# Usage:
#   ./release.sh          # build, sign, notarize, DMG, appcast
#   ./publish.sh          # then push the feed, tag, and cut the GitHub Release
#
# Two things have to happen for a release to reach users, and they are easy to
# confuse. Sparkle reads updates/appcast.xml, so installed copies update as soon
# as that folder is pushed. The README's download button points at
# /releases/latest, which is GitHub Releases — a separate system that a push
# does not touch. Skip the second and new downloaders get an old build.
#
# The feed lives in updates/ on the publish remote. This script commits that
# folder from a throwaway worktree, rather than pushing unrelated local changes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "$ROOT/release.config.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/release.config.sh"
fi

PUBLISH_REMOTE="${THREAD_PUBLISH_REMOTE:?not set — see release.config.sh.example}"
PUBLISH_REPO="${THREAD_PUBLISH_REPO:?not set — see release.config.sh.example}"
FEED_BRANCH="${THREAD_FEED_BRANCH:-main}"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")"
[[ -n "$VERSION" ]] || { echo "!! Could not read MARKETING_VERSION from project.yml"; exit 1; }

DMG="$ROOT/updates/Thread-$VERSION.dmg"
NOTES="$ROOT/release-notes/$VERSION.md"

echo "==> Publishing $VERSION to $PUBLISH_REPO"

[[ -f "$DMG" ]] || { echo "!! $DMG missing — run ./release.sh first"; exit 1; }
grep -q "Thread-$VERSION.dmg" "$ROOT/updates/appcast.xml" \
  || { echo "!! appcast.xml does not mention $VERSION — run ./release.sh first"; exit 1; }
[[ -f "$NOTES" ]] || { echo "!! Write user-facing notes at release-notes/$VERSION.md first"; exit 1; }
command -v gh >/dev/null || { echo "!! gh is required to cut the GitHub Release"; exit 1; }

# A repository without its own user.email inherits one built from the machine's
# hostname, which then lands in a public commit. Pin the expected address in
# release.config.sh and refuse to publish under anything else.
if [[ -n "${THREAD_COMMIT_EMAIL:-}" ]]; then
  ACTUAL="$(git -C "$ROOT" config user.email || true)"
  [[ "$ACTUAL" == "$THREAD_COMMIT_EMAIL" ]] || {
    echo "!! git user.email is '$ACTUAL', expected '$THREAD_COMMIT_EMAIL'"
    echo "   Fix with: git config user.email \"$THREAD_COMMIT_EMAIL\""
    exit 1
  }
fi

SOURCE_REF="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"

echo "==> Fetching the feed's current head"
git -C "$ROOT" fetch -q "$PUBLISH_REMOTE" "$FEED_BRANCH:refs/remotes/publish/$FEED_BRANCH" --force

WORKTREE="$(mktemp -d)/feed"
cleanup() { git -C "$ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true; }
trap cleanup EXIT

git -C "$ROOT" worktree add -q "$WORKTREE" --detach "refs/remotes/publish/$FEED_BRANCH"

# rsync rather than `git checkout -- updates/`, which copies additions but not
# the deletions generate_appcast makes when a version ages out of the feed.
echo "==> Syncing updates/ onto the feed"
rsync -a --delete "$ROOT/updates/" "$WORKTREE/updates/"
git -C "$WORKTREE" add -A updates

if git -C "$WORKTREE" diff --cached --quiet; then
  echo "==> Feed already matches; nothing to push"
else
  git -C "$WORKTREE" commit -q -F - <<EOF
Release $VERSION

$(cat "$NOTES")
EOF
  echo "==> Pushing the feed"
  git -C "$WORKTREE" push -q "$PUBLISH_REMOTE" "HEAD:$FEED_BRANCH"
fi

HEAD_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"

if gh release view "v$VERSION" --repo "$PUBLISH_REPO" >/dev/null 2>&1; then
  echo "==> Release v$VERSION already exists; leaving it alone"
else
  echo "==> Cutting the GitHub Release"
  # --latest explicitly: GitHub otherwise picks by its own ordering, and a
  # backfilled older release can end up as the one the download button serves.
  gh release create "v$VERSION" "$DMG" \
    --repo "$PUBLISH_REPO" \
    --target "$HEAD_SHA" \
    --title "Thread $VERSION" \
    --notes-file "$NOTES" \
    --latest
fi

echo ""
echo "✅ Published $VERSION from $SOURCE_REF."
echo "   Feed:     $PUBLISH_REMOTE ($FEED_BRANCH)"
echo "   Release:  https://github.com/$PUBLISH_REPO/releases/tag/v$VERSION"
