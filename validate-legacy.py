#!/usr/bin/env python3
"""
Dry-run validation for legacy Kyverno ClusterPolicy (apiVersion: kyverno.io/v1).
Checks YAML structure, kind, apiVersion, and rule structure without needing a cluster or Kyverno CRDs.

Usage:
  python3 validate-legacy.py sample-policies/complex-legacy-policy.yaml
  python3 validate-legacy.py --no-kubectl sample-policies/complex-legacy-policy.yaml
"""

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


def validate_legacy_policy(path: Path, use_kubectl: bool = True) -> tuple[bool, list[str]]:
    """Validate legacy ClusterPolicy file. Returns (passed, errors)."""
    errors: list[str] = []
    if not yaml:
        return (False, ["PyYAML not installed. pip install pyyaml"])

    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
        # Handle multi-doc: only validate first document (main policy)
        docs = list(yaml.safe_load_all(raw))
        doc = docs[0] if docs else None
    except Exception as e:
        return (False, [f"Invalid YAML: {e}"])

    if not doc or not isinstance(doc, dict):
        return (False, ["Empty or non-dict YAML document"])

    kind = (doc.get("kind") or "").strip()
    api_version = (doc.get("apiVersion") or "").strip()
    if kind != "ClusterPolicy":
        errors.append(f"Expected kind: ClusterPolicy, got {kind!r}")
    if not api_version.startswith("kyverno.io/"):
        errors.append(f"Expected apiVersion starting with 'kyverno.io/', got {api_version!r}")

    spec = doc.get("spec")
    if not spec or not isinstance(spec, dict):
        errors.append("Missing or invalid spec")
    else:
        rules = spec.get("rules")
        if not rules or not isinstance(rules, list):
            errors.append("spec.rules must be a non-empty list")
        else:
            for i, rule in enumerate(rules):
                if not isinstance(rule, dict):
                    errors.append(f"Rule {i}: not a dict")
                    continue
                name = rule.get("name") or f"<rule {i}>"
                if not rule.get("match"):
                    errors.append(f"Rule {name}: missing 'match'")
                validate_block = rule.get("validate")
                if not validate_block and "validate" not in rule:
                    # Mutate-only or generate-only rules exist; for validate we expect validate
                    if not rule.get("mutate") and not rule.get("generate"):
                        errors.append(f"Rule {name}: missing 'validate', 'mutate', or 'generate'")
                if validate_block and isinstance(validate_block, dict):
                    if not any(k in validate_block for k in ("pattern", "anyPattern", "deny", "message")):
                        errors.append(f"Rule {name}: validate should have pattern/anyPattern/deny and message")

    if errors:
        return (False, errors)

    # Optional: kubectl dry-run if CRDs might be installed
    if use_kubectl:
        import subprocess
        import shutil
        if shutil.which("kubectl"):
            proc = subprocess.run(
                ["kubectl", "apply", "-f", str(path), "--dry-run=client"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if proc.returncode != 0:
                err = (proc.stderr or proc.stdout or "").strip()
                if "no matches for kind" in err.lower() or "ensure crds" in err.lower():
                    # Expected when Kyverno CRDs are not installed
                    pass
                else:
                    errors.append(f"kubectl dry-run: {err[:400]}")
    return (len(errors) == 0, errors)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate legacy Kyverno ClusterPolicy (dry-run)")
    parser.add_argument("policy", type=Path, help="Path to ClusterPolicy YAML")
    parser.add_argument("--no-kubectl", action="store_true", help="Skip kubectl dry-run (schema only)")
    args = parser.parse_args()

    path = args.policy
    if not path.exists():
        print(f"Error: file not found: {path}", file=sys.stderr)
        return 1
    if not yaml:
        print("Error: PyYAML required. pip install pyyaml", file=sys.stderr)
        return 1

    passed, errors = validate_legacy_policy(path, use_kubectl=not args.no_kubectl)
    if passed:
        print("Validation: PASS (valid legacy ClusterPolicy)")
        return 0
    print("Validation: FAIL", file=sys.stderr)
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
