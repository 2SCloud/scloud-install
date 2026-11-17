#!/usr/bin/env bash
# Opens or updates one PR per (stack file, component) when a component has a
# newer GitHub release than the version pinned in the stack file:
#   stack.yml      ← latest release (pre-releases excluded)
#   stack-beta.yml ← latest release or pre-release (betas); alphas are never used
# A component is the GitHub repo <OWNER>/<component>. Components pinned to
# something that is not a version (main, latest...) are left alone, and a PR
# closed without merging is not reopened for the same version.
#
# Run from the root of a scloud-install checkout. Env:
#   GH_TOKEN    token allowed to push branches and open PRs on scloud-install
#   GH_REPO     owner/scloud-install
#   READ_TOKEN  token used to read the components' releases (default GH_TOKEN)
#   APP_SLUG    bot identity of the commits (default: github-actions)
#   OWNER       owner of the component repos (default 2SCloud)
#   ONLY        only this component (default: all)
#   RUN_URL     link added to the PR body

set -euo pipefail

OWNER="${OWNER:-2SCloud}"
ONLY="${ONLY:-}"
READ_TOKEN="${READ_TOKEN:-${GH_TOKEN:-}}"
STACKS=("stack.yml:stable" "stack-beta.yml:beta")
VERSION_RE='^[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.-]+)?$'
NAME_RE='^[A-Za-z0-9._-]+$'

if [[ -n "$ONLY" && ! "$ONLY" =~ $NAME_RE ]]; then
    echo "::error::Invalid component name: ${ONLY}"
    exit 1
fi

# Sort key for `sort -V`: 1.2.3-beta.4 → 1.2.3~beta.4 (before 1.2.3), 1.2.3-4 → 1.2.3.4 (after)
vkey() {
    if [[ "$1" =~ ^([0-9.]+)-([0-9]+)$ ]]; then
        printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s' "${1/-/'~'}"
    fi
}

sort_versions() {
    local v
    while IFS= read -r v; do
        if [[ -n "$v" ]]; then printf '%s\t%s\n' "$(vkey "$v")" "$v"; fi
    done | sort -t $'\t' -k1,1V | cut -f2
}

# ver_gt a b → a is newer than b
ver_gt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort_versions | tail -n1)" == "$1" ]]
}

# stack_get <component> <key> < file  (same reader as install.sh)
stack_get() {
    awk -v comp="$1" -v key="$2" '
        /^[ \t]*(#|$)/ { next }
        /^[^ \t]/      { c = $0; sub(/:.*/, "", c); next }
        c == comp {
            line = $0
            sub(/^[ \t]+/, "", line)
            k = line
            sub(/[ \t]*:.*/, "", k)
            if (k != key) next
            v = line
            sub(/^[^:]*:[ \t]*/, "", v)
            sub(/[ \t]+#.*$/, "", v)
            sub(/[ \t]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
            print v
            exit
        }
    '
}

# stack_set <file> <component> <version>: rewrites "version:" in the component block
stack_set() {
    sed -i -E "/^${2}:/,/^[^[:space:]#]/ s/^([[:space:]]+version:[[:space:]]*)[^#[:space:]]*/\1${3}/" "$1"
}

declare -A RELEASES=()

# fetch_releases <repo>: caches "tag<TAB>prerelease" of its published releases
fetch_releases() {
    local out
    if [[ -n "${RELEASES[$1]+x}" ]]; then return 0; fi
    out="$(GH_TOKEN="$READ_TOKEN" gh api "repos/${1}/releases?per_page=100" \
        --jq '.[] | select(.draft | not) | "\(.tag_name)\t\(.prerelease)"')" || return 1
    RELEASES[$1]="$out"
}

# latest_release <repo> stable|beta
latest_release() {
    printf '%s\n' "${RELEASES[$1]}" \
        | awk -F '\t' -v ch="$2" '$1 != "" && $1 !~ /-alpha/ && (ch == "beta" || $2 == "false") { print $1 }' \
        | { grep -E "$VERSION_RE" || true; } \
        | sort_versions | tail -n1
}

summary() {
    echo "$*"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "- $*" >> "$GITHUB_STEP_SUMMARY"; fi
}

# open_pr <file> <channel> <component> <current> <latest>
open_pr() {
    local file="$1" channel="$2" comp="$3" current="$4" latest="$5"
    local branch="bot/${file%.yml}/${comp}"
    local title="chore(${file%.yml}): bump ${comp} to ${latest}"
    local closed pr pinned="" body url

    closed="$(gh pr list --head "$branch" --state closed --json title --jq '.[].title')"
    if grep -qxF "$title" <<< "$closed"; then
        summary "${file} ${comp}: PR for ${latest} was closed, not reopened"
        return 0
    fi

    pr="$(gh pr list --head "$branch" --base "$BASE" --state open --json number --jq '.[0].number // empty')"

    if git fetch -q origin "refs/heads/${branch}" 2>/dev/null; then
        pinned="$(git show "FETCH_HEAD:${file}" 2>/dev/null | stack_get "$comp" version || true)"
    fi

    if [[ "$pinned" == "$latest" && -n "$pr" ]]; then
        summary "${file} ${comp}: PR #${pr} already proposes ${latest}"
        return 0
    fi

    if [[ "$pinned" != "$latest" ]]; then
        git switch -q -C "$branch" "$BASE_SHA"
        stack_set "$file" "$comp" "$latest"
        if [[ "$(stack_get "$comp" version < "$file")" != "$latest" ]]; then
            echo "::error::Could not set ${comp}.version in ${file}"
            git checkout -q -- "$file"
            git switch -q --detach "$BASE_SHA"
            return 1
        fi
        git commit -q -m "$title" -- "$file"
        git push -q --force origin "$branch"
        git switch -q --detach "$BASE_SHA"
    fi

    body="Bumps **${comp}** in \`${file}\` (${channel}): \`${current}\` → \`${latest}\`

- Release: https://github.com/${OWNER}/${comp}/releases/tag/${latest}
- Changes: https://github.com/${OWNER}/${comp}/compare/${current}...${latest}

Opened by the stack update workflow${RUN_URL:+: ${RUN_URL}}"

    if [[ -n "$pr" ]]; then
        gh pr edit "$pr" --title "$title" --body "$body" >/dev/null
        url="$(gh pr view "$pr" --json url --jq .url)"
    else
        url="$(gh pr create --base "$BASE" --head "$branch" --title "$title" --body "$body")"
    fi

    summary "${file} ${comp}: ${current} → ${latest} (${url})"
}

BASE="$(git branch --show-current)"
BASE_SHA="$(git rev-parse HEAD)"

if [[ -n "${APP_SLUG:-}" ]]; then
    user_id="$(gh api "/users/${APP_SLUG}[bot]" --jq .id)"
    git config user.name "${APP_SLUG}[bot]"
    git config user.email "${user_id}+${APP_SLUG}[bot]@users.noreply.github.com"
else
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi

failed=0

for entry in "${STACKS[@]}"
do
    file="${entry%%:*}"
    channel="${entry##*:}"

    if [[ ! -f "$file" ]]; then continue; fi

    for comp in $(grep -oE '^[A-Za-z0-9._-]+:' "$file" | tr -d ':')
    do
        if [[ -n "$ONLY" && "$comp" != "$ONLY" ]]; then continue; fi

        current="$(stack_get "$comp" version < "$file")"
        if [[ ! "$current" =~ $VERSION_RE ]]; then
            summary "${file} ${comp}: pinned to '${current}', skipped"
            continue
        fi

        repo="${OWNER}/${comp}"
        if ! fetch_releases "$repo"; then
            echo "::warning::Could not read the releases of ${repo}"
            failed=1
            continue
        fi

        latest="$(latest_release "$repo" "$channel")"
        if [[ -z "$latest" ]] || ! ver_gt "$latest" "$current"; then
            summary "${file} ${comp}: ${current} is up to date"
            continue
        fi

        open_pr "$file" "$channel" "$comp" "$current" "$latest" || failed=1
    done
done

git switch -q "$BASE"
exit "$failed"
