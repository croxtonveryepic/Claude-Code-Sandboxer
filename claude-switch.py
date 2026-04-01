"""Switch between Claude Code accounts by swapping credential files."""

import argparse
import copy
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

CLAUDE_DIR = Path.home() / ".claude"
CLAUDE_JSON_FILE = Path.home() / ".claude.json"
CREDENTIALS_FILE = CLAUDE_DIR / ".credentials.json"
PROFILES_DIR = CLAUDE_DIR / "profiles"
ACTIVE_FILE = PROFILES_DIR / ".active"
SCHEMA_VERSION = 3


# ── Helpers ──────────────────────────────────────────────────────────

def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text("utf-8"))
    except FileNotFoundError:
        print(f"Error: {path} not found. Are you logged into Claude Code?")
        sys.exit(1)
    except json.JSONDecodeError:
        print(f"Error: {path} contains invalid JSON.")
        sys.exit(1)


def read_json_safe(path: Path) -> Optional[dict]:
    """Read JSON, returning None on missing or invalid files."""
    try:
        return json.loads(path.read_text("utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def write_json_atomic(path: Path, data: dict) -> None:
    """Write JSON atomically via temp file + os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise


def read_oauth_account() -> dict:
    """Read the oauthAccount section from ~/.claude.json."""
    data = read_json(CLAUDE_JSON_FILE)
    return data.get("oauthAccount", {})


def read_oauth_account_safe() -> Optional[dict]:
    """Read the oauthAccount section, returning None on failure."""
    data = read_json_safe(CLAUDE_JSON_FILE)
    if data is None:
        return None
    return data.get("oauthAccount")


def write_oauth_account(oauth_account: dict) -> None:
    """Merge-write oauthAccount into ~/.claude.json, preserving all other keys."""
    data = read_json_safe(CLAUDE_JSON_FILE) or {}
    data["oauthAccount"] = oauth_account
    write_json_atomic(CLAUDE_JSON_FILE, data)


def hash_token(token: str) -> str:
    """SHA-256 hex digest of a refresh token."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def get_environment_id() -> str:
    """Return an identifier for this environment."""
    if os.environ.get("BOXER_CONTAINER") == "true":
        name = os.environ.get("BOXER_CONTAINER_NAME", "unknown")
        return f"container:{name}"
    return "host"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── Active profile marker ───────────────────────────────────────────

def read_active() -> Optional[dict]:
    """Read the .active marker file."""
    return read_json_safe(ACTIVE_FILE)


def write_active(profile_name: Optional[str], token: Optional[str]) -> None:
    """Write the .active marker file."""
    data = {
        "profile": profile_name,
        "token_sha256": hash_token(token) if token else None,
        "activated_at": now_iso(),
    }
    write_json_atomic(ACTIVE_FILE, data)


# ── Schema migration ────────────────────────────────────────────────

def migrate_profile(data: dict) -> dict:
    """Return a v3-format copy of a profile dict (no mutation)."""
    if data.get("schema_version") == SCHEMA_VERSION:
        return copy.deepcopy(data)
    migrated = copy.deepcopy(data)

    # v1 → v2: add token tracking fields
    migrated.setdefault("token_updated_at", data.get("saved_at", now_iso()))
    migrated.setdefault("token_updated_by", "unknown")

    # v2 → v3: rename "account" to "oauth_account" if possible
    if "oauth_account" not in migrated and "account" in migrated:
        old_account = migrated.pop("account")
        # Attempt to build oauth_account from the old nested structure
        acct = old_account.get("account", {})
        org = old_account.get("organization", {})
        migrated["oauth_account"] = {
            "emailAddress": acct.get("email", migrated.get("email", "unknown")),
            "organizationName": org.get("name", migrated.get("org", "unknown")),
        }
        # Update top-level email/org from the migrated data
        migrated["email"] = migrated["oauth_account"]["emailAddress"]
        migrated["org"] = migrated["oauth_account"]["organizationName"]

    migrated["schema_version"] = SCHEMA_VERSION
    return migrated


# ── Profile operations ──────────────────────────────────────────────

def load_profile(name: str) -> dict:
    path = PROFILES_DIR / f"{name}.json"
    if not path.exists():
        print(f"Error: Profile '{name}' not found.")
        print(f"Available profiles: {', '.join(list_profile_names()) or '(none)'}")
        sys.exit(1)
    data = json.loads(path.read_text("utf-8"))
    return migrate_profile(data)


def list_profile_names() -> list[str]:
    if not PROFILES_DIR.exists():
        return []
    return sorted(p.stem for p in PROFILES_DIR.glob("*.json"))


def get_active_refresh_token() -> Optional[str]:
    if not CREDENTIALS_FILE.exists():
        return None
    creds = read_json_safe(CREDENTIALS_FILE)
    if creds is None:
        return None
    return creds.get("claudeAiOauth", {}).get("refreshToken")


def check_running_claude() -> bool:
    """Return True if claude processes are running (besides this script).

    Skipped entirely inside Sandboxer containers (BOXER_CONTAINER=true).
    Uses platform-appropriate detection: tasklist on Windows, pgrep on Linux/macOS.
    """
    if os.environ.get("BOXER_CONTAINER") == "true":
        return False

    try:
        if platform.system() == "Windows":
            result = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq claude.exe", "/FO", "CSV", "/NH"],
                capture_output=True, text=True, timeout=5,
            )
            for line in result.stdout.strip().splitlines():
                if "claude.exe" in line.lower():
                    return True
        else:
            result = subprocess.run(
                ["pgrep", "-x", "claude"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                return True
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return False


# ── Freshen logic (reusable) ────────────────────────────────────────

def synthesize_active_from_token(*, quiet: bool = False) -> bool:
    """Reconstruct .active by matching the live token to a saved profile.

    Returns True if .active was synthesized, False otherwise.
    """
    live_token = get_active_refresh_token()
    if not live_token:
        if not quiet:
            print("No live credentials found, cannot synthesize .active")
        return False
    live_hash = hash_token(live_token)
    for pname in list_profile_names():
        p = read_json_safe(PROFILES_DIR / f"{pname}.json")
        if p is None:
            continue
        prof_token = p.get("claude_ai_oauth", {}).get("refreshToken")
        if prof_token and hash_token(prof_token) == live_hash:
            write_active(pname, live_token)
            if not quiet:
                print(f"  Detected active profile: '{pname}'")
            return True
    if not quiet:
        print("No profile matches the live token.")
    return False


def freshen_active_profile(*, quiet: bool = False) -> bool:
    """Freshen the active profile from live credentials.

    Returns True if the profile was updated, False otherwise.
    """
    active = read_active()
    if not active or not active.get("profile"):
        if not quiet:
            print("No active profile to freshen.")
        return False

    profile_name = active["profile"]
    profile_path = PROFILES_DIR / f"{profile_name}.json"
    if not profile_path.exists():
        if not quiet:
            print(f"Warning: Active profile '{profile_name}' file not found, skipping freshen.")
        return False

    live_token = get_active_refresh_token()
    if not live_token:
        if not quiet:
            print("No live credentials found, skipping freshen.")
        return False

    # Compare against stored hash
    stored_hash = active.get("token_sha256")
    live_hash = hash_token(live_token)
    if stored_hash == live_hash:
        if not quiet:
            print(f"Profile '{profile_name}' is current, no freshening needed.")
        return False

    # Token has rotated — update the profile
    profile_data = json.loads(profile_path.read_text("utf-8"))
    updated = migrate_profile(profile_data)

    live_creds = read_json_safe(CREDENTIALS_FILE)
    if live_creds and "claudeAiOauth" in live_creds:
        updated["claude_ai_oauth"] = live_creds["claudeAiOauth"]

    live_oauth = read_oauth_account_safe()
    if live_oauth:
        updated["oauth_account"] = live_oauth
        updated["email"] = live_oauth.get("emailAddress", updated.get("email", "unknown"))
        updated["org"] = live_oauth.get("organizationName", updated.get("org", "unknown"))
    updated.pop("account", None)

    env_id = get_environment_id()
    updated["token_updated_at"] = now_iso()
    updated["token_updated_by"] = env_id

    write_json_atomic(profile_path, updated)
    write_active(profile_name, live_token)

    if not quiet:
        print(f"Freshened profile '{profile_name}' (token rotated, captured by {env_id}).")
    return True


# ── Commands ─────────────────────────────────────────────────────────

def cmd_save(args: argparse.Namespace) -> None:
    name = args.name
    profile_path = PROFILES_DIR / f"{name}.json"

    if profile_path.exists() and not args.overwrite:
        existing = json.loads(profile_path.read_text("utf-8"))
        print(f"Profile '{name}' already exists ({existing.get('email', '?')}).")
        print("Use --overwrite to replace it.")
        sys.exit(1)

    creds = read_json(CREDENTIALS_FILE)
    oauth_account = read_oauth_account()

    oauth = creds.get("claudeAiOauth")
    if not oauth:
        print("Error: No claudeAiOauth found in credentials. Are you logged in?")
        sys.exit(1)

    ts = now_iso()

    profile = {
        "name": name,
        "email": oauth_account.get("emailAddress", "unknown"),
        "org": oauth_account.get("organizationName", "unknown"),
        "subscription_type": oauth.get("subscriptionType", "unknown"),
        "saved_at": ts,
        "token_updated_at": ts,
        "token_updated_by": get_environment_id(),
        "schema_version": SCHEMA_VERSION,
        "claude_ai_oauth": oauth,
        "oauth_account": oauth_account,
    }

    write_json_atomic(profile_path, profile)

    # Update .active to point to this profile
    refresh_token = oauth.get("refreshToken")
    write_active(name, refresh_token)

    print(f"Saved profile '{name}':")
    print(f"  Email: {profile['email']}")
    print(f"  Org:   {profile['org']}")
    print(f"  Type:  {profile['subscription_type']}")


def cmd_use(args: argparse.Namespace) -> None:
    name = args.name

    # Check if already on this profile (by name via .active, not token matching)
    active = read_active()
    if active and active.get("profile") == name:
        profile = load_profile(name)
        live_token = get_active_refresh_token()
        if live_token and active.get("token_sha256") != hash_token(live_token):
            freshen_active_profile(quiet=False)
            print(f"Profile '{name}' was stale and has been freshened.")
        else:
            print(f"Already on profile '{name}' ({profile['email']}).")
        return

    # Auto-freshen the outgoing profile before switching
    if active and active.get("profile"):
        try:
            freshen_active_profile(quiet=True)
        except Exception as exc:
            print(f"Warning: Failed to freshen outgoing profile: {exc}", file=sys.stderr)

    profile = load_profile(name)

    # Warn about running sessions
    if check_running_claude() and not args.force:
        print("Warning: Claude Code appears to be running.")
        print("Exit all Claude Code sessions first, or use --force to switch anyway.")
        sys.exit(1)

    # Warn if another environment recently updated this profile
    updated_by = profile.get("token_updated_by", "")
    updated_at = profile.get("token_updated_at", "")
    env_id = get_environment_id()
    if updated_by and updated_by != env_id and updated_by != "unknown" and updated_at:
        try:
            updated_dt = datetime.fromisoformat(updated_at)
            age_seconds = (datetime.now(timezone.utc) - updated_dt).total_seconds()
            if age_seconds < 300:  # within 5 minutes
                print(f"Warning: Profile '{name}' was updated by {updated_by} at {updated_at}.")
                print("Using the same profile in multiple environments simultaneously may cause token conflicts.")
        except (ValueError, TypeError):
            pass

    # Read current credentials to preserve mcpOAuth
    current_creds = read_json_safe(CREDENTIALS_FILE) or {}

    # Swap only claudeAiOauth, keep everything else
    current_creds["claudeAiOauth"] = profile["claude_ai_oauth"]
    write_json_atomic(CREDENTIALS_FILE, current_creds)

    # Update oauthAccount in ~/.claude.json
    if "oauth_account" in profile:
        write_oauth_account(profile["oauth_account"])
    else:
        print(f"Warning: Profile '{name}' uses old format — re-save it to capture account info.")
        print(f"  Run: claude-switch save {name} --overwrite")

    # Update .active marker
    refresh_token = profile["claude_ai_oauth"].get("refreshToken")
    write_active(name, refresh_token)

    print(f"Switched to '{name}':")
    print(f"  Email: {profile['email']}")
    print(f"  Org:   {profile['org']}")
    print(f"  Type:  {profile['subscription_type']}")


def cmd_freshen(args: argparse.Namespace) -> None:
    names = list_profile_names()
    if not names:
        if not args.quiet:
            print("No profiles to freshen.")
        return

    # Step 1: Migrate all profiles to current schema
    if not args.quiet:
        print(f"Migrating profiles to v{SCHEMA_VERSION} format...")
    migrated = 0
    for pname in names:
        path = PROFILES_DIR / f"{pname}.json"
        data = json.loads(path.read_text("utf-8"))
        if data.get("schema_version") != SCHEMA_VERSION:
            updated = migrate_profile(data)
            write_json_atomic(path, updated)
            migrated += 1
            if not args.quiet:
                print(f"  Migrated '{pname}' to schema v{SCHEMA_VERSION}")
    if migrated == 0 and not args.quiet:
        print(f"  All profiles already at v{SCHEMA_VERSION}.")

    # Step 2: Synthesize .active if missing
    if not args.quiet:
        print("Checking .active marker...")
    if not read_active():
        synthesize_active_from_token(quiet=args.quiet)
    elif not args.quiet:
        active = read_active()
        print(f"  .active already set: '{active.get('profile')}'")

    # Step 3: Freshen the active profile from live credentials
    if not args.quiet:
        print("Freshening active profile...")
    freshen_active_profile(quiet=args.quiet)

    if not args.quiet:
        print(f"Done. {migrated} profile(s) migrated.")


def cmd_status(args: argparse.Namespace) -> None:
    profiles = list_profile_names()

    if not profiles:
        print("No profiles saved. Use 'save <name>' to capture the current account.")
        return

    # Determine active profile from .active marker, fall back to token matching
    active = read_active()
    active_name = active.get("profile") if active else None

    # Fallback: if .active is missing, try token matching (backward compat)
    if not active_name:
        active_token = get_active_refresh_token()
        if active_token:
            for pname in profiles:
                p = json.loads((PROFILES_DIR / f"{pname}.json").read_text("utf-8"))
                if p.get("claude_ai_oauth", {}).get("refreshToken") == active_token:
                    active_name = pname
                    break

    # Detect staleness: live token differs from what .active recorded
    stale = False
    if active and active_name:
        live_token = get_active_refresh_token()
        if live_token:
            live_hash = hash_token(live_token)
            stale = active.get("token_sha256") != live_hash

    print("Profiles:")
    for pname in profiles:
        p = json.loads((PROFILES_DIR / f"{pname}.json").read_text("utf-8"))
        p = migrate_profile(p)
        marker = " *" if pname == active_name else "  "
        stale_tag = " (stale)" if pname == active_name and stale else ""
        updated_by = p.get("token_updated_by", "")
        updated_at = p.get("token_updated_at", "")
        updated_info = ""
        if updated_at:
            short_ts = updated_at[:19].replace("T", " ")
            updated_info = f"  updated {short_ts}"
            if updated_by and updated_by != "unknown":
                updated_info += f" by {updated_by}"
        print(f"{marker} {pname:12s}  {p['email']:40s}  {p['subscription_type']}{stale_tag}{updated_info}")

    if active_name:
        suffix = " (stale — run 'cs freshen' to update)" if stale else ""
        print(f"\nActive: {active_name}{suffix}")
    else:
        print("\nActive: (no matching profile)")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="claude-switch",
        description="Switch between Claude Code accounts.",
    )
    sub = parser.add_subparsers(dest="command")

    p_save = sub.add_parser("save", help="Capture current account as a named profile")
    p_save.add_argument("name", help="Profile name (e.g. 'work', 'personal')")
    p_save.add_argument("--overwrite", action="store_true", help="Overwrite existing profile")

    p_use = sub.add_parser("use", help="Switch to a named profile")
    p_use.add_argument("name", help="Profile name to switch to")
    p_use.add_argument("--force", action="store_true", help="Switch even if Claude is running")

    sub.add_parser("status", help="Show active account and all profiles")

    p_freshen = sub.add_parser("freshen", help="Migrate profiles, synthesize .active if needed, and update from live credentials")
    p_freshen.add_argument("--quiet", "-q", action="store_true", help="Suppress output")

    args = parser.parse_args()

    if args.command == "save":
        cmd_save(args)
    elif args.command == "use":
        cmd_use(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "freshen":
        cmd_freshen(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
