import subprocess
import sys
from pathlib import Path


SOURCE_PATH = Path(
    "src/backend/engines/agent_runner/templates/skills/kedacode-operator/SKILL.md"
)
REQUIRED_PHRASES = (
    "`kc issue create` publishes the PRD and its handoff context",
    "not merely a single Issue",
    "before creation",
    "every PRD-referenced companion file is committed and pushed to the base branch",
)


def check_source(source_path: Path) -> int:
    skill_text = source_path.read_text(encoding="utf-8")
    shared_baseline = skill_text.split(
        "## Shared baselines (apply to every route)", maxsplit=1
    )[1].split("\n## ", maxsplit=1)[0]
    handoff_statement = next(
        (line for line in shared_baseline.splitlines() if "handoff context" in line),
        "",
    )
    missing_phrases = [phrase for phrase in REQUIRED_PHRASES if phrase not in handoff_statement]
    if missing_phrases:
        print(f"FAIL: missing required wording: {missing_phrases[0]}")
        return 1
    print("PASS: shared baseline includes PRD context and the base-branch prerequisite")
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
        "every PRD-referenced companion file is committed and pushed to the base branch",
        "PRD companion files are available",
        1,
    )
    control_path = Path(__file__).resolve().with_name(".rv-3-control.md")
    control_path.write_text(control_text, encoding="utf-8")
    try:
        negative_control = run_oracle(control_path)
    finally:
        control_path.unlink(missing_ok=True)
    if negative_control.returncode != 1:
        raise SystemExit("NEGATIVE CONTROL ERROR: mutated oracle did not exit 1")
    print("NEGATIVE CONTROL: removed the base-branch prerequisite from the shared baseline")
    print(negative_control.stdout.rstrip())
    print(f"negative_control_exit={negative_control.returncode}")

    green_result = run_oracle(SOURCE_PATH)
    print("GREEN COMMAND: same shared-baseline oracle against the packaged source file")
    print(green_result.stdout.rstrip())
    if green_result.returncode != 0:
        raise SystemExit(f"GREEN CHECK FAILED: oracle exited {green_result.returncode}")
    print(f"green_exit={green_result.returncode}")
    return 0


raise SystemExit(main())
