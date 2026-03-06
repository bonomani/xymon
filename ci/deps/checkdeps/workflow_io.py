"""Workflow YAML parsing helpers for dependency checks."""

from __future__ import annotations

from pathlib import Path

import yaml


def parse_workflow_yaml(path: Path) -> dict:
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"Workflow root is not a mapping: {path}")
    return data


def find_package_steps(workflow: dict) -> list[str]:
    jobs = workflow.get("jobs")
    found = []
    if not isinstance(jobs, dict):
        return found

    for job_name, job_body in jobs.items():
        if not isinstance(job_body, dict):
            continue
        steps = job_body.get("steps")
        if not isinstance(steps, list):
            continue
        for step in steps:
            if not isinstance(step, dict):
                continue
            run = step.get("run")
            if isinstance(run, str) and "install-default-packages.sh" in run:
                found.append(job_name)
    return found
