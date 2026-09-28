#!/bin/bash
# An exact-item boundary, not an invocation of `mo clean`.
# stdout is reserved for the worker protocol; upstream diagnostics go to stderr.
set -euo pipefail
base=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
export MOLE_DRY_RUN=1 MOLE_CURRENT_COMMAND=clean BURROWBOLT_READ_ONLY=1
# Classification needs only the installer module. Live action/process guards
# still run when planning/applying; avoid an lsof sweep for every read-only ZIP.
if [[ "${2:-}" == inspect-zip ]]; then
    [[ -f "${1:-}" && ! -L "$1" && -O "$1" ]] || exit 30
    source "$base/mole/bin/installer.sh" >&2
    trap 'cleanup_temp_files' EXIT
    is_installer_zip "$1" >&2 || exit 31
    printf 'allowed\n'
    exit 0
fi
source "$base/mole/bin/clean.sh" >&2
source "$base/mole/lib/clean/project.sh" >&2
readonly DRY_RUN=true
# Deny authorization instead of using Mole's test flags, which also suppress
# production process evidence. The worker never runs privileged actions.
sudo() { return 1; }
request_sudo_access() { return 1; }
request_sudo_access_with_password() { return 1; }
ensure_sudo_session() { return 1; }
ensure_sudo_session_with_password() { return 1; }
has_sudo_session() { return 1; }
_mole_bounded_sudo() { return 1; }
trap 'cleanup_temp_files' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
path=${1:?exact path required}
kind=${2:?rule required}
root=${3:?project root required}
readonly _BB_SELECTED_PATH="$path" _BB_MODE="$kind"
# Families run only in Mole's dry-run mode. Capture the structured append boundary,
# never terminal text. Selective validation reruns the same family and stops at
# the exact supported sink, with its dynamically-scoped owner guards intact.
if [[ "$kind" == family:* || "$kind" == discover:* ]]; then
    family=${kind#*:}
    allowed=false
    while IFS= read -r name; do [[ "$family" != "$name" ]] || allowed=true; done < "$base/families.txt"
    [[ "$allowed" == true ]] || exit 34
    CLEAN_PREVIEW_LEDGER_FILE=$(create_temp_file)
    EXPORT_LIST_FILE=""
    CURRENT_SECTION=$family
    readonly _BB_DEADLINE=$((SECONDS + 20))
    _MOLE_CLEAN_SECTION_DEADLINE=$_BB_DEADLINE
    append_dry_run_cleanup_target() {
        local candidate="$1" action=informational caller
        for caller in "${FUNCNAME[@]}"; do
            [[ "$caller" != _safe_clean_impl ]] || action=review
        done
        if [[ "$_BB_MODE" == discover:* ]]; then
            printf '%s\0%s\0%s\0' "$candidate" "$action" "${description:-$family}" >&3
        elif [[ "$candidate" == "$_BB_SELECTED_PATH" && "$action" == review ]]; then
            # The worker consumes this signal immediately, then stops the entire
            # dry-run process group. No unrelated item can become an action.
            printf 'allowed\n' >&3
            # Preserve the just-validated dynamic scope until the worker stops us.
            while :; do /bin/sleep 1; done
        fi
    }
    burrowbolt_informational_target() {
        if [[ "$_BB_MODE" == discover:* ]]; then
            printf '%s\0informational\0%s\0' "$1" "$2" >&3
        fi
    }
    exec 3>&1
    # Match Mole _run_cleanup_step: conditional context intentionally tolerates
    # non-required/no-match statuses, but never timeouts or cancellation.
    family_status=0
    "$family" >&2 || family_status=$?
    [[ $family_status -lt 124 && "${MOLE_CLEAN_CANCEL_STATUS:-0}" == 0 && $SECONDS -lt $_BB_DEADLINE ]] || exit 124
    exit 0
fi
[[ -O "$path" && ! -L "$path" ]] || exit 20
validate_path_for_deletion "$path" >&2 || exit 21
is_path_whitelisted "$path" && exit 22
holds_compiled_model_cache "$path" && exit 23
case "$kind" in
    project)
        found=false
        for target in "${PURGE_TARGETS[@]}"; do
            [[ "${path##*/}" != "$target" ]] || found=true
        done
        [[ "$found" == true ]] || exit 24
        # The parent must be an actual project, never a package inside another artifact.
        project=${path%/*}
        is_purge_project_root "$project" || exit 25
        parent=$project
        while [[ "$parent" != / ]]; do
            for target in "${PURGE_TARGETS[@]}"; do
                [[ "${parent##*/}" != "$target" ]] || exit 26
            done
            parent=${parent%/*}; [[ -n "$parent" ]] || parent=/
        done
        is_safe_project_artifact "$path" "$project" || exit 27
        is_protected_purge_artifact "$path" && exit 28
        purge_target_activity_still_safe "$path" old || exit 29
        ;;
    installer|installer-zip)
        [[ -f "$path" ]] || exit 30
        case "$path" in
            *.dmg|*.pkg|*.mpkg|*.iso|*.xip) ;;
            *.zip)
                source "$base/mole/bin/installer.sh" >&2
                trap 'cleanup_temp_files' EXIT
                is_installer_zip "$_BB_SELECTED_PATH" >&2 || exit 31
                ;;
            *) exit 31 ;;
        esac
        ;;
    *) exit 32 ;; # New rule families require their own evidence and tests.
esac
# Reuse Mole's complete-process-visibility and recursive handle predicate for
# selected native targets too. An unprivileged partial lsof view is unknown.
open_status=0
_mole_container_cache_has_open_handle "$_BB_SELECTED_PATH" || open_status=$?
[[ $open_status -eq 1 ]] || exit 35
# Reuse upstream's common live-cache and database guards. This has no removal sink.
# Replace only the output boundary; record_dry_run_cleanup_target still runs its checks.
append_dry_run_cleanup_target() { return 0; }
register_dry_run_cleanup_target() { return 0; }
record_dry_run_cleanup_target "$path" 0 1 false >&2 || exit 33
printf 'allowed\n'
