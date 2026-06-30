#!/usr/bin/env python3
"""Execute the service-account scoping steps defined in a YAML file.

Reads scope_service_account.steps.yaml, fills in the placeholders from the
`config:` block (env vars of the same UPPERCASE name take precedence), writes
the temporary --users-file YAMLs, and runs each step's command in order.

Usage:
    python3 run_steps.py [path-to-steps.yaml] [--dry-run]

Must be run as an Anyscale organization owner.
"""
import os
import re
import subprocess
import sys
import tempfile

import yaml

STEPS_FILE = "scope_service_account.steps.yaml"


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def resolve_config(doc):
    """Config values, with env-var overrides (UPPERCASE key)."""
    cfg = dict(doc.get("config") or {})
    for k in list(cfg):
        cfg[k] = os.environ.get(k.upper(), cfg[k])
    # org-id is discovered at runtime, not configured.
    cfg.setdefault("org_id", "<org-id>")
    return cfg


def subst(text, cfg):
    """Replace <name>, <cloud>, <project>, <org-id> placeholders."""
    for key in ("name", "cloud", "project", "org_id"):
        text = text.replace(f"<{key.replace('_', '-')}>", str(cfg[key]))
    return text


ANSI = re.compile(r"\x1b\[[0-9;]*[mGKHF]")


def extract_email(text, name):
    """Find <name>@org-<id>.serviceaccount.com, reconstructing from org-id
    if the full email is truncated."""
    text = ANSI.sub("", text)
    m = re.search(rf"{re.escape(name)}@org-[a-z0-9]+\.serviceaccount\.com", text)
    if m:
        return m.group(0)
    m = re.search(r"org-[a-z0-9]+", text)
    if m:
        return f"{name}@{m.group(0)}.serviceaccount.com"
    return None


def run(cmd, dry_run, capture=False):
    print(f"   $ {cmd}")
    if dry_run:
        return ""
    if capture:
        # Stream to the terminal AND capture, so the API key is still visible.
        proc = subprocess.run(cmd, shell=True, text=True, capture_output=True)
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        if proc.returncode != 0:
            sys.exit(f"!! command failed (exit {proc.returncode})")
        return proc.stdout + proc.stderr
    proc = subprocess.run(cmd, shell=True)
    if proc.returncode != 0:
        sys.exit(f"!! command failed (exit {proc.returncode})")
    return ""


def write_users_file(contents, cfg, email, role, tmpdir, name):
    """Render a users_file_contents block to a temp YAML, injecting the
    resolved SA email and the configured permission_level."""
    rendered = yaml.safe_load(subst(yaml.safe_dump(contents), cfg))
    for collab in rendered.get("collaborators", []):
        collab["email"] = email
        if role:
            collab["permission_level"] = role
    path = os.path.join(tmpdir, name)
    with open(path, "w") as f:
        yaml.safe_dump(rendered, f, default_flow_style=False)
    print(f"   (wrote {name}: {rendered['collaborators']})")
    return path


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv
    path = args[0] if args else STEPS_FILE

    doc = load(path)
    cfg = resolve_config(doc)
    name = cfg["name"]

    if dry_run:
        print(">> DRY RUN — no commands will be executed\n")
    print(f">> Config: {cfg}\n")

    email = os.environ.get("SA_EMAIL", "")

    with tempfile.TemporaryDirectory() as tmpdir:
        for step in doc["steps"]:
            print(f">> Step {step['id']}: {step['name']}")

            if "users_file_contents" in step:
                if not email:
                    sys.exit("!! no service-account email resolved yet "
                             "(step 1 must run first, or set SA_EMAIL)")
                fname = step.get("users_file", f"users-{step['id']}.yaml")
                # Pick the configured role by command target.
                if "project add-collaborators" in step["command"]:
                    role = cfg.get("project_role")
                elif "cloud add-collaborators" in step["command"]:
                    role = cfg.get("cloud_role")
                else:
                    role = None
                fpath = write_users_file(
                    step["users_file_contents"], cfg, email, role, tmpdir, fname)
                cmd = subst(step["command"], cfg).replace(fname, fpath)
                run(cmd, dry_run)
            else:
                # Step 1: create the SA and resolve its email.
                cmd = subst(step["command"], cfg)
                out = run(cmd, dry_run, capture=True)
                if not email:
                    email = extract_email(out, name) if not dry_run else \
                        f"{name}@<org-id>.serviceaccount.com"
                if not email and not dry_run:
                    out = run("anyscale service-account list", dry_run, capture=True)
                    email = extract_email(out, name)
                if not email and not dry_run:
                    email = input("Enter the service account email: ").strip()
                print(f"   service account email: {email}")
            print()

    print(">> Done.")


if __name__ == "__main__":
    main()
