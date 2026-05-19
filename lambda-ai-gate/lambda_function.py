import json
from typing import Any, Dict


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Simple AI gate stub.
    In the next iteration, this will call Amazon Bedrock.
    For now, it makes a deterministic decision based on tests + diff size.
    """

    # Expect event like:
    # {
    #   "commit_sha": "...",
    #   "branch": "main",
    #   "tests": {"status": "passed", "total": 25, "failed": 0},
    #   "diff": {"files_changed": 3, "insertions": 120, "deletions": 12},
    #   "service": {"name": "task-tracker-api", "environment": "prod"}
    # }

    tests = event.get("tests", {}) or {}
    diff = event.get("diff", {}) or {}
    branch = event.get("branch", "unknown")

    status = tests.get("status", "unknown")
    failed = tests.get("failed", 0)
    files_changed = diff.get("files_changed", 0)
    insertions = diff.get("insertions", 0)
    deletions = diff.get("deletions", 0)

    # Basic rule-based “AI” for now:
    # - If tests failed: block.
    # - If huge diff on main: warn.
    # - Otherwise: approve.

    reasons = []
    risk_score = 0
    decision = "approve"

    if status != "passed" or failed > 0:
        decision = "block"
        risk_score = 90
        reasons.append("Tests did not pass cleanly.")
    else:
        reasons.append("All tests passed.")

    total_changes = insertions + deletions
    if branch == "main" and total_changes > 500:
        if decision != "block":
            decision = "warn"
            risk_score = max(risk_score, 60)
        reasons.append(
            f"Large change set on main ({files_changed} files, {total_changes} lines)."
        )
    else:
        reasons.append(
            f"Change set size appears moderate ({files_changed} files, {total_changes} lines)."
        )

    if decision == "approve" and risk_score == 0:
        risk_score = 10

    return {
        "decision": decision,
        "risk_score": risk_score,
        "reasons": reasons,
    }