"""第 4 项 oracle：随包 Skill 守卫、改动范围、安装副本与门禁回归检查。

四段真实入口证据：

1. 命令漂移守卫负控：临时向受管 references 文件注入一个不存在的 kc flag，真实运行
   ``uv run pytest tests/test_kedacode_operator_skill.py -q`` 必须转红；恢复原字节后同一
   命令必须全绿。
2. 范围证明：以 ``git merge-base main HEAD`` 为基线枚举整个工作树，逐条分类，任何未列入
   允许集合的路径都会让脚本 exit 1。允许集合只有两类：本 Issue 的两份 Skill 文档、以及
   与 ``main`` 当前版本逐字节一致的基线测试同步。结构化证据 manifest 必须存在于本地供
   runner 读取，但被本地 ``.gitignore`` 忽略且未跟踪，因此不出现在 diff 中。
3. 安装副本检查：用 ``KEDACODE_SKILLS_DIR`` 把 ``kc skill install --force`` 落到
   worktree 内的隔离目录，逐字节比较全部受管文件；再只读复核用户级安装根。命令、
   安装函数与合并后要执行的步骤相同；合并不会改变随包文件内容。
4. 门禁回归检查：上一轮 ``just test all`` 失败的 6 个 node id 现在必须全部通过；它们由
   ``main`` 的 ``fix(ci): restore main validation`` 修复，本分支只是同步了同一份测试。
"""

import os
import re
import shutil
import subprocess
from pathlib import Path


SKILL_TEMPLATE_DIR = "src/backend/engines/agent_runner/templates/skills/kedacode-operator/"
PACKAGED_SKILL_DIR = Path(SKILL_TEMPLATE_DIR)
SKILL_FILE_NAMES = ("SKILL.md", "references/create-issue.md")
SOURCE_PATH = Path(f"{SKILL_TEMPLATE_DIR}{SKILL_FILE_NAMES[1]}")
EXPECTED_SKILL_PATHS = {f"{SKILL_TEMPLATE_DIR}{name}" for name in SKILL_FILE_NAMES}
RUNNER_MANIFEST_PATH = "tasks/evidence/issue-291/evidence.json"
IMPLEMENTATION_PATH = "src/backend/core/use_cases/create_issue_from_prd.py"
INSTALL_ROOT = Path("tasks/evidence/issue-291/.skill-install-root")
INSTALLED_SKILL_DIR = INSTALL_ROOT / "kedacode-operator"
PYTEST_COMMAND = ["uv", "run", "pytest", "tests/test_kedacode_operator_skill.py", "-q"]
GATE_TEST_IDS = (
    "tests/test_agent_runner_console_api.py::test_process_lifecycle_via_api",
    "tests/test_agent_runner_console_api.py::test_duplicate_daemon_rejected_via_api",
    "tests/test_agent_runner_console_api.py::test_audit_endpoint_lists_actions",
    "tests/test_worktree_cli.py::test_create_or_reuse_worktree_links_frontend_node_modules",
    "tests/test_worktree_frontend.py::TestEnsureFrontendNodeModules"
    "::test_stale_main_checkout_lockfiles_are_not_reused",
    "tests/test_worktree_frontend.py::TestLinkFrontendNodeModules"
    "::test_links_node_modules_for_root_and_nested_projects",
)
COMMAND_ENV = os.environ.copy()
COMMAND_ENV["PYTEST_ADDOPTS"] = "--no-testmon"


def run_command(
    command: list[str], env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env or COMMAND_ENV,
    )


original_bytes = SOURCE_PATH.read_bytes()
original_text = original_bytes.decode("utf-8")
negative_control_text = (
    original_text
    + "\n\n<!-- negative control -->\n"
    + "`kc issue create --rv-not-a-real-flag tasks/pending/example.md`\n"
)

try:
    SOURCE_PATH.write_text(negative_control_text, encoding="utf-8")
    negative_control = run_command(PYTEST_COMMAND)
finally:
    SOURCE_PATH.write_bytes(original_bytes)

negative_output = negative_control.stdout + negative_control.stderr
print(f"negative_control_returncode={negative_control.returncode}")
print("pytest_environment=PYTEST_ADDOPTS=--no-testmon (runs every test in the target file)")
print("negative_control_output_summary:")
print("\n".join(negative_output.strip().splitlines()[-18:]))
if negative_control.returncode == 0:
    raise SystemExit("NEGATIVE CONTROL ERROR: invalid CLI example unexpectedly passed pytest")
if "--rv-not-a-real-flag" not in negative_output:
    raise SystemExit(
        "NEGATIVE CONTROL ERROR: pytest failed without identifying the injected invalid flag"
    )
print("NEGATIVE CONTROL: uv run pytest tests/test_kedacode_operator_skill.py -q")
print("expected_fail=pytest rejects --rv-not-a-real-flag as a CLI flag absent from --help")
print(f"negative_control_exit={negative_control.returncode}")

positive_test = run_command(PYTEST_COMMAND)
positive_output = positive_test.stdout + positive_test.stderr
print("GREEN COMMAND: uv run pytest tests/test_kedacode_operator_skill.py -q")
print(positive_output.rstrip())
if positive_test.returncode != 0:
    raise SystemExit(f"GREEN CHECK FAILED: targeted pytest exited {positive_test.returncode}")
print(f"green_pytest_exit={positive_test.returncode}")

base_ref = run_command(["git", "merge-base", "main", "HEAD"])
if base_ref.returncode != 0:
    raise SystemExit(f"GREEN CHECK FAILED: git merge-base main HEAD exited {base_ref.returncode}")
base_commit = base_ref.stdout.strip()

# 工作树包含本轮尚未提交的改动，直接与 merge base 比对才能同时覆盖已提交与工作区内容。
diff_names = run_command(["git", "diff", "--name-only", base_commit])
if diff_names.returncode != 0:
    raise SystemExit(f"GREEN CHECK FAILED: git diff --name-only exited {diff_names.returncode}")
changed_paths = sorted(path for path in diff_names.stdout.splitlines() if path.strip())
print("GREEN COMMAND: git diff --name-only <merge-base main HEAD>")
print(f"base_commit={base_commit}")
print("\n".join(changed_paths))

skill_changes = {path for path in changed_paths if path.startswith(SKILL_TEMPLATE_DIR)}
if skill_changes != EXPECTED_SKILL_PATHS:
    raise SystemExit(f"GREEN CHECK FAILED: skill changes were {sorted(skill_changes)}")

# tests/ 下只允许同步 main 已有的基线修复：逐字节比对，任何本分支自创的测试改动都拒绝。
synced_test_paths: list[str] = []
for path in changed_paths:
    if not path.startswith("tests/"):
        continue
    main_blob = run_command(["git", "show", f"main:{path}"])
    if main_blob.returncode != 0:
        raise SystemExit(f"GREEN CHECK FAILED: {path} is absent from main")
    if Path(path).read_bytes() != main_blob.stdout.encode("utf-8"):
        raise SystemExit(f"GREEN CHECK FAILED: {path} differs from main's current version")
    synced_test_paths.append(path)

# 结构化证据 manifest 必须留作 runner 的本地交付物，但不得进入代码 diff：
# 它存在且可读，同时被本地 .gitignore 忽略、未被 git 跟踪。
manifest_path = Path(RUNNER_MANIFEST_PATH)
if not manifest_path.is_file():
    raise SystemExit(f"GREEN CHECK FAILED: {RUNNER_MANIFEST_PATH} is missing")
if run_command(["git", "check-ignore", "-q", RUNNER_MANIFEST_PATH]).returncode != 0:
    raise SystemExit(f"GREEN CHECK FAILED: {RUNNER_MANIFEST_PATH} is not locally ignored")
if run_command(["git", "ls-files", "--error-unmatch", RUNNER_MANIFEST_PATH]).returncode == 0:
    raise SystemExit(f"GREEN CHECK FAILED: {RUNNER_MANIFEST_PATH} is still tracked")
print("runner_manifest_local_only=1")
print("runner_manifest_in_diff=0")

unexpected_paths = [
    path
    for path in changed_paths
    if path not in EXPECTED_SKILL_PATHS and path not in synced_test_paths
]
if unexpected_paths:
    raise SystemExit(f"GREEN CHECK FAILED: unexpected changed paths {unexpected_paths}")
print(
    "scope_paths: "
    f"skill_changes={len(skill_changes)}; "
    f"test_changes_match_main={len(synced_test_paths)}; "
    "unexpected=0"
)
print("scope_non_allowed_paths=0")

implementation_diff = run_command(
    ["git", "diff", "--name-only", base_commit, "--", IMPLEMENTATION_PATH]
)
if implementation_diff.returncode != 0 or implementation_diff.stdout.strip():
    raise SystemExit("GREEN CHECK FAILED: publish_prd_file implementation has a diff")
print("GREEN: publish_prd_file implementation unchanged; no CLI source file changed")
print("green_diff_exit=0")

# 与合并后步骤相同的真实安装入口：只落 worktree 内的隔离 skills root。
shutil.rmtree(INSTALL_ROOT, ignore_errors=True)
install_env = os.environ.copy()
install_env["KEDACODE_SKILLS_DIR"] = str(INSTALL_ROOT.resolve())
install_env["UV_CACHE_DIR"] = os.environ.get(
    "UV_CACHE_DIR", f"{os.environ.get('TMPDIR', '/tmp')}/keda-issue-291-uv-cache"
)
print("GREEN COMMAND: KEDACODE_SKILLS_DIR=<isolated> uv run kc skill install --force")
managed_relative_paths = sorted(
    path.relative_to(PACKAGED_SKILL_DIR) for path in PACKAGED_SKILL_DIR.rglob("*.md")
)
if not managed_relative_paths:
    raise SystemExit("GREEN CHECK FAILED: packaged skill has no managed markdown files")
try:
    install_result = run_command(
        ["uv", "run", "kc", "skill", "install", "--force"], env=install_env
    )
    install_output = install_result.stdout + install_result.stderr
    print("\n".join(install_output.strip().splitlines()[-10:]))
    print(f"install_command_exit={install_result.returncode}")
    if install_result.returncode != 0:
        raise SystemExit(
            f"GREEN CHECK FAILED: kc skill install exited {install_result.returncode}"
        )
    if not INSTALLED_SKILL_DIR.is_dir():
        raise SystemExit(f"GREEN CHECK FAILED: {INSTALLED_SKILL_DIR} was not installed")
    mismatched_paths = [
        relative_path.as_posix()
        for relative_path in managed_relative_paths
        if (PACKAGED_SKILL_DIR / relative_path).read_bytes()
        != (INSTALLED_SKILL_DIR / relative_path).read_bytes()
    ]
    print(
        "installed_managed_files="
        f"{len(managed_relative_paths)}; mismatched={len(mismatched_paths)}"
    )
    if mismatched_paths:
        raise SystemExit(
            f"GREEN CHECK FAILED: installed copy differs for {mismatched_paths}"
        )
    print("installed_copy_matches_packaged_source=true")
finally:
    shutil.rmtree(INSTALL_ROOT, ignore_errors=True)

# 用户级安装发生在合并后；dry-run 只读列出真实入口会同步的全部安装根。
# 不把尚未执行的刷新报告成已完成，也不覆盖用户拥有的远程模板 Skill。
user_install_env = os.environ.copy()
user_install_env.pop("KEDACODE_SKILLS_DIR", None)
user_install_env["UV_CACHE_DIR"] = install_env["UV_CACHE_DIR"]
print("GREEN COMMAND: env -u KEDACODE_SKILLS_DIR uv run kc skill install --dry-run")
user_install_preview = run_command(
    ["uv", "run", "kc", "skill", "install", "--dry-run"], env=user_install_env
)
user_install_preview_output = user_install_preview.stdout + user_install_preview.stderr
if user_install_preview.returncode != 0:
    raise SystemExit(
        "GREEN CHECK FAILED: kc skill install --dry-run exited "
        f"{user_install_preview.returncode}"
    )
print(f"user_skill_dry_run_exit={user_install_preview.returncode}")

user_skill_roots = sorted(set(re.findall(r"/[^,\s]+/skills", user_install_preview_output)))
if not user_skill_roots:
    raise SystemExit("GREEN CHECK FAILED: dry-run reported no user skill roots")
user_mismatches = [
    skills_root
    for skills_root in user_skill_roots
    if any(
        not (Path(skills_root) / "kedacode-operator" / relative_path).is_file()
        or (Path(skills_root) / "kedacode-operator" / relative_path).read_bytes()
        != (PACKAGED_SKILL_DIR / relative_path).read_bytes()
        for relative_path in managed_relative_paths
    )
]
print(
    f"user_skill_roots_detected={len(user_skill_roots)}; "
    f"current_matches={len(user_skill_roots) - len(user_mismatches)}; "
    f"current_mismatches={len(user_mismatches)}; "
    f"refresh_pending={len(user_mismatches)}"
)
if user_mismatches:
    print("post_merge_user_skill_refresh=pending")
else:
    print("post_merge_user_skill_refresh=not_needed")

# 上一轮 `just test all` 的 6 个失败 node id：main 修复后本分支必须全绿。
gate_tests = run_command(["uv", "run", "pytest", "-q", "--no-testmon", *GATE_TEST_IDS])
gate_output = gate_tests.stdout + gate_tests.stderr
print("GREEN COMMAND: uv run pytest -q --no-testmon <previously failing gate node ids>")
print("\n".join(gate_output.strip().splitlines()[-8:]))
print(f"gate_regression_tests_exit={gate_tests.returncode}")
if gate_tests.returncode != 0:
    raise SystemExit(
        f"GREEN CHECK FAILED: previously failing gate tests exited {gate_tests.returncode}"
    )
print(f"previously_failing_gate_tests=passed ({len(GATE_TEST_IDS)})")
