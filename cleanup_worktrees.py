#!/usr/bin/env python3
import argparse
import fnmatch
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def run(cmd, check=True, cwd=None):
    return subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        check=check,
        cwd=cwd,
    )


def resolve_git_path(base_dir, value):
    path = Path(value.strip())
    if not path.is_absolute():
        path = Path(base_dir) / path
    return path.resolve()


def git_root():
    try:
        result = run(["git", "rev-parse", "--show-toplevel"])
    except subprocess.CalledProcessError:
        print("Not inside a Git repository.", file=sys.stderr)
        sys.exit(1)
    return Path(result.stdout.strip()).resolve()


def git_common_dir(repo_root):
    result = run(["git", "rev-parse", "--git-common-dir"], cwd=repo_root)
    return resolve_git_path(repo_root, result.stdout)


def git_dir_for_worktree(path):
    result = run(
        ["git", "-C", str(path), "rev-parse", "--git-dir"],
        check=False,
    )

    if result.returncode != 0:
        return None

    return resolve_git_path(path, result.stdout)


def parse_worktrees():
    result = run(["git", "worktree", "list", "--porcelain", "-z"])
    parts = result.stdout.split("\0")

    worktrees: list[dict[str, Any]] = []
    current: dict[str, Any] = {}

    for part in parts:
        if not part:
            if current:
                worktrees.append(current)
                current = {}
            continue

        key, _, value = part.partition(" ")

        if key == "worktree":
            if current:
                worktrees.append(current)
            current = {"path": value}
        elif key == "branch":
            current["branch"] = value.removeprefix("refs/heads/")
        elif key == "HEAD":
            current["head"] = value
        elif key == "bare":
            current["bare"] = True
        elif key == "detached":
            current["detached"] = True

    if current:
        worktrees.append(current)

    return worktrees


def parse_age(value):
    """
    Accepts values like:
      2d, 12h, 30m, 7days
    """
    value = value.strip().lower()

    units = {
        "m": 60,
        "min": 60,
        "mins": 60,
        "minute": 60,
        "minutes": 60,
        "h": 3600,
        "hr": 3600,
        "hrs": 3600,
        "hour": 3600,
        "hours": 3600,
        "d": 86400,
        "day": 86400,
        "days": 86400,
    }

    for suffix, multiplier in sorted(units.items(), key=lambda item: -len(item[0])):
        if value.endswith(suffix):
            number = value[: -len(suffix)].strip()
            return float(number) * multiplier

    raise ValueError(f"Could not parse age: {value}. Try values like 2d, 12h, 30m.")


def format_age(seconds):
    if seconds < 3600:
        return f"{seconds / 60:.1f}m"
    if seconds < 86400:
        return f"{seconds / 3600:.1f}h"
    return f"{seconds / 86400:.1f}d"


def branch_matches(branch, patterns):
    return any(fnmatch.fnmatchcase(branch, pattern) for pattern in patterns)


def add_skip(skipped, path, branch_label, reason):
    skipped.append((path, branch_label, reason))


def age_file_for_worktree(git_dir, signal):
    """
    Git does not expose a public creation timestamp for worktrees.

    Better signals than worktree directory mtime:
      - git-head: mtime of .git/worktrees/<name>/HEAD
      - git-dir:  mtime of .git/worktrees/<name> directory
    """
    if git_dir is None:
        return None

    if signal == "git-head":
        return git_dir / "HEAD"

    if signal == "git-dir":
        return git_dir

    raise ValueError(f"Unknown age signal: {signal}")


def worktree_age_seconds(git_dir, signal):
    age_file = age_file_for_worktree(git_dir, signal)

    if age_file is None or not age_file.exists():
        return None

    return time.time() - os.path.getmtime(age_file)


def pid_from_lock_reason(reason):
    """
    Claude Code lock reasons conventionally include text like:
      claude agent agent-a5caf54b (pid 48988)

    Git does not define a standard PID format for lock reasons; this parser
    only handles tools that include 'pid N' in the reason.
    """
    if not reason:
        return None

    match = re.search(r"\bpid\s+(\d+)\b", reason)
    if not match:
        return None

    return int(match.group(1))


def pid_is_alive(pid):
    """
    macOS/Linux: os.kill(pid, 0) checks whether a process exists.

    Returns:
      True  -> process exists
      False -> process does not exist
      None  -> permission denied, invalid PID, or unknown

    Note: PID reuse can cause stale locks to look live if the OS has
    reassigned the old PID to an unrelated process. That is a safe
    false-negative: the script refuses to remove the worktree.
    """
    if pid <= 0:
        return None

    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return None


def unlocked_info():
    return {
        "locked": False,
        "lock_reason": None,
        "lock_pid": None,
        "lock_pid_alive": None,
    }


def lock_info_for_worktree(git_dir):
    if git_dir is None:
        return unlocked_info()

    locked_file = git_dir / "locked"

    if not locked_file.exists():
        return unlocked_info()

    try:
        reason = locked_file.read_text(errors="replace").strip()
    except OSError:
        reason = ""

    pid = pid_from_lock_reason(reason)
    alive = pid_is_alive(pid) if pid is not None else None

    return {
        "locked": True,
        "lock_reason": reason,
        "lock_pid": pid,
        "lock_pid_alive": alive,
    }


def lock_status_text(wt):
    if not wt.get("locked"):
        return ""

    pid = wt.get("lock_pid")
    alive = wt.get("lock_pid_alive")

    if pid is not None and alive is False:
        return f"locked=dead-pid:{pid}"

    if pid is not None and alive is True:
        return f"locked=live-pid:{pid}"

    if pid is not None:
        return f"locked=unknown-pid:{pid}"

    return "locked=no-pid"


def should_skip_locked_worktree(args, wt):
    if not wt.get("locked"):
        return None

    pid = wt.get("lock_pid")
    alive = wt.get("lock_pid_alive")

    if args.force >= 2:
        return None

    if args.remove_dead_locks and pid is not None and alive is False:
        return None

    status = lock_status_text(wt)

    if pid is not None and alive is False:
        return f"{status}; pass --remove-dead-locks to override safely"

    if pid is not None and alive is True:
        return f"{status}; refusing to override live lock"

    if pid is not None:
        return f"{status}; refusing to override unknown PID state"

    return f"{status}; refusing to override lock without PID"


def list_dirty_entries(path):
    result = run(
        ["git", "-C", str(path), "status", "--porcelain"],
        check=False,
    )

    if result.returncode != 0:
        return []

    return [line for line in result.stdout.splitlines() if line.strip()]


def remove_worktree(path, force_count):
    cmd = ["git", "worktree", "remove"]

    for _ in range(force_count):
        cmd.append("--force")

    cmd.append(str(path))

    result = run(cmd, check=False)

    if result.returncode != 0:
        print(f"Failed to remove worktree: {path}", file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)

        for entry in list_dirty_entries(path):
            print(f"  {entry}", file=sys.stderr)

        return False

    return True


def delete_branch(branch):
    result = run(["git", "branch", "-D", branch], check=False)

    if result.returncode != 0:
        print(f"Failed to delete branch: {branch}", file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)
        return False

    return True


def confirm_apply(count):
    if count <= 3:
        return True

    try:
        answer = input(f"Delete {count} worktrees? [y/N] ").strip().lower()
    except EOFError:
        print("(stdin not interactive — aborting)", file=sys.stderr)
        return False
    return answer in {"y", "yes"}


def branch_would_be_deleted(args, branch, keep_patterns):
    return (
        args.delete_branch
        and branch
        and not branch_matches(branch, keep_patterns)
    )


def force_count_for_worktree(args, wt):
    force_count = args.force

    if (
        args.remove_dead_locks
        and wt.get("locked")
        and wt.get("lock_pid") is not None
        and wt.get("lock_pid_alive") is False
    ):
        force_count = max(force_count, 2)

    return force_count


def print_worktree_match(wt, args, keep_patterns):
    path = wt["resolved_path"]
    branch = wt.get("branch")
    branch_label = wt["branch_label"]
    age = wt["age"]

    age_text = f"  age={format_age(age)}" if age is not None else ""

    branch_delete_text = ""
    if branch_would_be_deleted(args, branch, keep_patterns):
        branch_delete_text = f"  +delete-branch={branch}"

    force_count = force_count_for_worktree(args, wt)
    force_text = ""
    if force_count == 1:
        force_text = "  force=dirty-ok"
    elif force_count >= 2:
        force_text = "  force=locked-ok"

    lock_text_raw = lock_status_text(wt)
    lock_text = f"  {lock_text_raw}" if lock_text_raw else ""

    print(f"  {path}  branch={branch_label}{age_text}{branch_delete_text}{force_text}{lock_text}")

    for entry in list_dirty_entries(path):
        print(f"    {entry}")


def main():
    parser = argparse.ArgumentParser(
        description="Clean up Git worktrees, especially temporary Claude Code worktrees."
    )

    parser.add_argument(
        "--keep-branch",
        action="append",
        default=None,
        help=(
            "Branch pattern to keep. Can be repeated. "
            "Supports globs like 'release/*'. Default: main"
        ),
    )

    parser.add_argument(
        "--older-than",
        help="Only delete worktrees older than this age, e.g. 2d, 12h, 30m.",
    )

    parser.add_argument(
        "--age-signal",
        choices=["git-head", "git-dir"],
        default="git-head",
        help=(
            "Signal used for --older-than. "
            "git-head = last checkout-ish Git activity. "
            "git-dir = worktree metadata directory mtime. "
            "Default: git-head"
        ),
    )

    parser.add_argument(
        "--path-contains",
        help="Only delete worktrees whose path contains this string, e.g. claude.",
    )

    parser.add_argument(
        "--dead-locks-only",
        action="store_true",
        help=(
            "Only target locked worktrees whose lock reason contains a dead 'pid N'. "
            "Implies --remove-dead-locks."
        ),
    )

    parser.add_argument(
        "--remove-dead-locks",
        action="store_true",
        help=(
            "If a worktree is locked with a lock reason containing 'pid N', "
            "override the lock only when that PID is no longer alive. "
            "PID reuse can make a stale lock appear live; use --force --force "
            "for an intentional manual override."
        ),
    )

    parser.add_argument(
        "--include-current",
        action="store_true",
        help="Allow deleting the current worktree. Not recommended.",
    )

    parser.add_argument(
        "--force",
        action="count",
        default=0,
        help=(
            "Pass --force to git worktree remove. "
            "Use once for dirty worktrees; use twice to override locked worktrees."
        ),
    )

    parser.add_argument(
        "--delete-branch",
        action="store_true",
        help="Delete the local branch after successfully removing its worktree.",
    )

    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually delete matching worktrees. Without this, only prints what would be deleted.",
    )

    parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip confirmation prompt, which is only shown when removing more than 3 worktrees.",
    )

    parser.add_argument(
        "--prune",
        action="store_true",
        help="Run git worktree prune after removals.",
    )

    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print skipped worktrees and reasons.",
    )

    args = parser.parse_args()

    if args.dead_locks_only:
        args.remove_dead_locks = True

    repo_root = git_root()
    common_dir = git_common_dir(repo_root)

    # Anchor cwd to the primary repo root so removing the worktree we were
    # launched from (with --include-current) doesn't leave subsequent git
    # calls running from a deleted directory.
    os.chdir(common_dir.parent)

    keep_patterns = args.keep_branch or ["main"]
    max_age = parse_age(args.older_than) if args.older_than else None

    matches = []
    skipped = []

    for wt in parse_worktrees():
        path = Path(wt["path"]).resolve()
        branch = wt.get("branch")
        branch_label = branch or "<detached>"

        git_dir = git_dir_for_worktree(path)
        is_primary = git_dir == common_dir if git_dir else False

        wt["resolved_path"] = path
        wt["branch_label"] = branch_label
        wt["git_dir"] = git_dir
        wt["age"] = None
        wt.update(lock_info_for_worktree(git_dir))

        if is_primary:
            add_skip(skipped, path, branch_label, "primary worktree")
            continue

        if not args.include_current and path == repo_root:
            add_skip(skipped, path, branch_label, "current worktree")
            continue

        if branch and branch_matches(branch, keep_patterns):
            add_skip(skipped, path, branch_label, f"kept branch pattern: {branch}")
            continue

        if args.path_contains and args.path_contains not in str(path):
            add_skip(
                skipped,
                path,
                branch_label,
                f"path does not contain: {args.path_contains}",
            )
            continue

        if args.dead_locks_only:
            if not (
                wt.get("locked")
                and wt.get("lock_pid") is not None
                and wt.get("lock_pid_alive") is False
            ):
                add_skip(skipped, path, branch_label, "not locked with a dead PID")
                continue

        lock_skip_reason = should_skip_locked_worktree(args, wt)
        if lock_skip_reason:
            add_skip(skipped, path, branch_label, lock_skip_reason)
            continue

        if max_age is not None:
            age = worktree_age_seconds(git_dir, args.age_signal)

            if age is None:
                add_skip(
                    skipped,
                    path,
                    branch_label,
                    f"could not read age signal: {args.age_signal}",
                )
                continue

            wt["age"] = age

            if age < max_age:
                add_skip(skipped, path, branch_label, f"too new: {format_age(age)}")
                continue

        matches.append(wt)

    if args.verbose and skipped:
        print("Skipped worktrees:")
        for path, branch_label, reason in skipped:
            print(f"  {path}  branch={branch_label}  reason={reason}")
        print()

    if not matches:
        print("No matching worktrees found.")
        return

    print("Matching worktrees:")
    for wt in matches:
        print_worktree_match(wt, args, keep_patterns)

    if not args.apply:
        print("\nDry run only. Re-run with --apply to delete these worktrees.")
        return

    if not args.yes and not confirm_apply(len(matches)):
        print("Aborted.")
        return

    print()

    for wt in matches:
        path = wt["resolved_path"]
        branch = wt.get("branch")

        removed = remove_worktree(
            path,
            force_count=force_count_for_worktree(args, wt),
        )

        if not removed:
            continue

        print(f"Removed worktree: {path}")

        if branch_would_be_deleted(args, branch, keep_patterns):
            deleted = delete_branch(branch)

            if deleted:
                print(f"Deleted branch: {branch}")

    if args.prune:
        run(["git", "worktree", "prune"], check=False)
        print("Ran git worktree prune.")


if __name__ == "__main__":
    main()