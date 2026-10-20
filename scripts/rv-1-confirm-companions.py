import subprocess
import sys
from pathlib import Path


SOURCE_PATH = Path(
    "src/backend/engines/agent_runner/templates/skills/kedacode-operator/references/create-issue.md"
)
REQUIRED_PHRASES = (
    "run `git status --porcelain` before creating the Issue",
    "commit the PRD's referenced prototypes, design docs, diagrams, evidence scripts, "
    "screenshots, and other companion files",
    "in a normal commit on the branch that will be pushed",
    "Committed files travel with that branch push; "
    "uncommitted or untracked files do not reach the base branch.",
    "Do not pre-`git add` companion files",
    "`kc issue create` publishes only the PRD and rejects an index containing non-PRD files",
)


def check_source(source_path: Path) -> int:
    skill_text = source_path.read_text(encoding="utf-8")
    confirm_section = skill_text.split("## Confirm before acting", maxsplit=1)[1]
    confirm_section = confirm_section.split("\n## ", maxsplit=1)[0]
    confirm_sixth_item = next(
        (line for line in confirm_section.splitlines() if line.startswith("6.")),
        "",
    )
    missing_phrases = [phrase for phrase in REQUIRED_PHRASES if phrase not in confirm_sixth_item]
    if missing_phrases:
        print(f"FAIL: missing required wording: {missing_phrases[0]}")
        return 1
    print("PASS: Confirm before acting item 6 satisfies all 6 wording assertions")
    return 0


def run_oracle(source_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(Path(__file__).resolve()), "--check-source", str(source_path)],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--check-source":
        return check_source(Path(sys.argv[2]))

    source_text = SOURCE_PATH.read_text(encoding="utf-8")
    control_text = source_text.replace(
        "run `git status --porcelain` before creating the Issue",
        "inspect the working tree before creating the Issue",
        1,
    )
    control_path = Path(__file__).resolve().with_name(".rv-1-control.md")
    control_path.write_text(control_text, encoding="utf-8")
    try:
        negative_control = run_oracle(control_path)
    finally:
        control_path.unlink(missing_ok=True)
    if negative_control.returncode != 1:
        raise SystemExit("NEGATIVE CONTROL ERROR: mutated oracle did not exit 1")
    print("NEGATIVE CONTROL: removed git status --porcelain from a temporary copy of item 6")
    print(negative_control.stdout.rstrip())
    print(f"negative_control_exit={negative_control.returncode}")

    green_result = run_oracle(SOURCE_PATH)
    print("GREEN COMMAND: same wording oracle against the packaged source file")
    print(green_result.stdout.rstrip())
    if green_result.returncode != 0:
        raise SystemExit(f"GREEN CHECK FAILED: oracle exited {green_result.returncode}")
    print(f"green_exit={green_result.returncode}")
    return 0


raise SystemExit(main())
