import subprocess
import sys
from pathlib import Path


SOURCE_PATH = Path(
    "src/backend/engines/agent_runner/templates/skills/kedacode-operator/references/create-issue.md"
)
REQUIRED_PHRASES = (
    "Creating the Issue alone is **not a completed handoff**",
    "the deliverable includes the PRD's companion files on the base branch",
    "After creation, run `git status --porcelain`",
    "any PRD-related files remain uncommitted or untracked",
    "report the result as `partial`",
    "do not claim the deliverable is complete",
)


def check_source(source_path: Path) -> int:
    skill_text = source_path.read_text(encoding="utf-8")
    execute_section = skill_text.split("## Execute and never do", maxsplit=1)[1]
    execute_section = execute_section.split("\n## ", maxsplit=1)[0]
    handoff_statement = next(
        (line for line in execute_section.splitlines() if "not a completed handoff" in line),
        "",
    )
    missing_phrases = [phrase for phrase in REQUIRED_PHRASES if phrase not in handoff_statement]
    if missing_phrases:
        print(f"FAIL: missing required wording: {missing_phrases[0]}")
        return 1
    print("PASS: Execute and never do defines incomplete handoffs as partial")
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
        "report the result as `partial`",
        "report the result as pending",
        1,
    )
    control_path = Path(__file__).resolve().with_name(".rv-2-control.md")
    control_path.write_text(control_text, encoding="utf-8")
    try:
        negative_control = run_oracle(control_path)
    finally:
        control_path.unlink(missing_ok=True)
    if negative_control.returncode != 1:
        raise SystemExit("NEGATIVE CONTROL ERROR: mutated oracle did not exit 1")
    print("NEGATIVE CONTROL: replaced the partial reporting requirement with pending")
    print(negative_control.stdout.rstrip())
    print(f"negative_control_exit={negative_control.returncode}")

    green_result = run_oracle(SOURCE_PATH)
    print("GREEN COMMAND: same handoff oracle against the packaged source file")
    print(green_result.stdout.rstrip())
    if green_result.returncode != 0:
        raise SystemExit(f"GREEN CHECK FAILED: oracle exited {green_result.returncode}")
    print(f"green_exit={green_result.returncode}")
    return 0


raise SystemExit(main())
