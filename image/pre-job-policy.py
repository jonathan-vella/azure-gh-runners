import json
import os
import re
import stat
import subprocess
import sys


class Rejection(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Rejection(reason)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def parse_json(text):
    return json.loads(text, object_pairs_hook=unique_object)


def branch_ref(value):
    require(isinstance(value, str) and value.startswith("refs/heads/"), "invalid branch ref")
    require(
        subprocess.run(
            ["/usr/bin/git", "check-ref-format", value],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        ).returncode == 0,
        "invalid branch ref",
    )
    return value


def workflow_parts(value):
    require(isinstance(value, str), "invalid workflow ref")
    require(not re.search(r"[\x00-\x20\x7f]", value), "invalid workflow ref")
    match = re.fullmatch(r"([^/]+/[^/]+)/\.github/workflows/([^/@\s\\]+\.(?i:ya?ml))@(refs/.+)",
                        value)
    require(match is not None, "invalid workflow ref")
    return match.groups()


def validate():
    raw = os.environ.get("CONSUMER_POLICY_JSON", "")
    require(0 < len(raw) <= 65536, "missing or oversized consumer policy")
    policy = parse_json(raw)
    require(isinstance(policy, dict) and set(policy) == {
        "repository", "visibility", "allowedEvents", "allowedRefs", "allowedWorkflows",
    }, "invalid consumer policy fields")
    repo = policy["repository"]
    require(isinstance(repo, str) and re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}", repo
    ), "invalid policy repository")
    visibility = policy["visibility"]
    require(visibility in ("public", "private"), "invalid policy visibility")
    for key in ("allowedEvents", "allowedRefs", "allowedWorkflows"):
        values = policy[key]
        require(isinstance(values, list) and values and all(
            isinstance(value, str) and value for value in values
        ), "invalid policy allowlist")
        require(len(set(values)) == len(values), "duplicate policy allowlist entry")
    events = {"push", "schedule", "workflow_dispatch"}
    if visibility == "private":
        events.add("pull_request")
    require(set(policy["allowedEvents"]) <= events, "policy violates event floor")
    refs = policy["allowedRefs"]
    for ref in refs:
        branch_ref(ref)
    # The registry validator verifies this sole public ref against GitHub's default branch.
    require(visibility != "public" or len(refs) == 1, "public policy requires one default ref")
    workflows = set()
    for workflow in policy["allowedWorkflows"]:
        workflow_repo, workflow_file, workflow_ref = workflow_parts(workflow)
        require(workflow_repo.lower() == repo.lower() and workflow_ref in refs,
                "policy workflow outside repository or refs")
        branch_ref(workflow_ref)
        workflows.add((workflow_repo.lower(), workflow_file, workflow_ref))

    context = {}
    for key in ("GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_REF", "GITHUB_WORKFLOW_REF"):
        value = os.environ.get(key, "")
        require(value and not re.search(r"[\x00-\x20\x7f]", value), "missing or invalid job context")
        context[key] = value
    require(context["GITHUB_REPOSITORY"].lower() == repo.lower(), "repository outside policy")
    event = context["GITHUB_EVENT_NAME"]
    require(event in policy["allowedEvents"], "event outside policy")
    job_ref = context["GITHUB_REF"]
    workflow_repo, workflow_file, workflow_ref = workflow_parts(context["GITHUB_WORKFLOW_REF"])
    require(workflow_repo.lower() == repo.lower(), "workflow repository outside policy")

    if event == "pull_request":
        event_path = os.environ.get("GITHUB_EVENT_PATH", "")
        require(event_path, "missing pull request payload")
        descriptor = os.open(event_path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, encoding="utf-8") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "invalid pull request payload file")
            payload_text = stream.read(1048577)
        require(len(payload_text) <= 1048576, "oversized pull request payload")
        payload = parse_json(payload_text)
        require(isinstance(payload, dict), "invalid pull request payload")
        pr = payload.get("pull_request")
        require(isinstance(pr, dict) and pr.get("state") == "open", "pull request is not open")
        number = payload.get("number")
        require(type(number) is int and number > 0 and type(pr.get("number")) is int and
                pr["number"] == number,
                "invalid pull request number")
        expected_ref = f"refs/pull/{number}/merge"
        require(job_ref == expected_ref and workflow_ref == expected_ref,
                "pull request job or workflow is not its merge ref")
        for repository in (payload.get("repository"), pr.get("base", {}).get("repo"),
                           pr.get("head", {}).get("repo")):
            require(isinstance(repository, dict) and
                    isinstance(repository.get("full_name"), str) and
                    repository["full_name"].lower() == repo.lower() and
                    repository.get("private") is True and repository.get("fork") is False,
                    "pull request repository mismatch or fork")
        base = pr["base"].get("ref")
        head = pr["head"].get("ref")
        require(isinstance(base, str) and isinstance(head, str), "missing pull request branches")
        base_ref = branch_ref(f"refs/heads/{base}")
        branch_ref(f"refs/heads/{head}")
        require(os.environ.get("GITHUB_BASE_REF") == base and
                os.environ.get("GITHUB_HEAD_REF") == head, "pull request branch context mismatch")
        require(base_ref in refs, "pull request base outside policy")
        # PR workflows run from the merge ref, not from the allowlisted base branch ref.
        authorized_workflow = (repo.lower(), workflow_file, base_ref)
    else:
        require(job_ref in refs, "job ref outside policy")
        require(workflow_ref == job_ref, "workflow ref differs from job ref")
        authorized_workflow = (repo.lower(), workflow_file, workflow_ref)
    require(authorized_workflow in workflows, "workflow outside policy")


if __name__ == "__main__":
    try:
        validate()
    except Rejection as error:
        print(f"::error::Consumer policy rejected job: {error}.", file=sys.stderr)
        sys.exit(1)
    except (ValueError, TypeError, KeyError, AttributeError, OSError, RecursionError,
            subprocess.SubprocessError):
        print("::error::Consumer policy rejected job: invalid policy or event metadata.", file=sys.stderr)
        sys.exit(1)
    print("Consumer policy accepted job.")
