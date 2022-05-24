bats_require_minimum_version 1.5.0

load common.sh

run_script() {
	declare timestamp=${1:-"1"} tasks=${2:-""}
	{
cat << EOF
#!/usr/bin/env python3
import os
from deploy import Deployment, Skip, SymlinkedRelease
deploy = Deployment(targets={
    "localhost": {},
})
release = SymlinkedRelease(
		current_path=os.environ["BATS_TEST_TMPDIR"] + "/current",
		shared_dir=os.environ["BATS_TEST_TMPDIR"] + "/shared",
		linked_paths={"test.log": "data/test.log"},
		keep=1,
		timestamp=${timestamp},
)
EOF
		if [ -n "$tasks" ]; then
			echo "$tasks"
		else
			cat
		fi
		echo
		echo "deploy.run()"
	} > "$TEST_SCRIPT"
	chmod +x "$TEST_SCRIPT"
	run -0 "$TEST_SCRIPT"
}

setup_file() {
	setup_ssh
	git config --global --add safe.directory /test
}

simple_deployment() {
cat << EOF
@deploy.task()
def t(target):
		release.detect_releases(target)
		release.copy(target, ["tests/symlinked-release.bats"])
		release.link_shared(target)
		release.link(target)
		release.remove_old(target)
EOF
}

setup() {
	mkdir -p "$BATS_TEST_TMPDIR"
	export PYTHONPATH="/test"
	export TEST_SCRIPT="${BATS_TEST_TMPDIR}/script.py"
	SIMPLE_DEPLOYMENT=$(simple_deployment)
	export SIMPLE_DEPLOYMENT
	declare i
	for i in $(seq 20); do
		sleep 0.01
		nc -z -w 1 localhost 22 || continue
		break
	done
	pushd /test >/dev/null
}

teardown() {
	rm -rf "$BATS_TEST_TMPDIR"
	popd >/dev/null
}

@test "detect releases in fresh environment" {
run_script << EOF
@deploy.task()
def t(target):
		release.detect_releases(target)
EOF
}

@test "link shared paths" {
	run_script "1" "$SIMPLE_DEPLOYMENT"
	[ -e "${BATS_TEST_TMPDIR}/releases/1" ]
	[ -e "${BATS_TEST_TMPDIR}/releases/1/tests/symlinked-release.bats" ]
	mkdir -p "${BATS_TEST_TMPDIR}/shared/data"
	declare text="sample-text"
	echo "$text" > "${BATS_TEST_TMPDIR}/shared/data/test.log"
	run -0 cat "${BATS_TEST_TMPDIR}/releases/1/test.log"
	[ "$text" = "$output" ]
	[ -e "${BATS_TEST_TMPDIR}/releases/1" ]
	[ -e "${BATS_TEST_TMPDIR}/releases/1/tests/symlinked-release.bats" ]
}

@test "manage releases" {
	declare text="sample-text"
	run_script "1" "$SIMPLE_DEPLOYMENT"
	mkdir -p "${BATS_TEST_TMPDIR}/shared/data"
	echo "$text" > "${BATS_TEST_TMPDIR}/shared/data/test.log"
	run_script "2" "$SIMPLE_DEPLOYMENT"
	run_script "3" "$SIMPLE_DEPLOYMENT"
	run -0 ls -1 "${BATS_TEST_TMPDIR}/releases"
	[ "${#lines[@]}" = 2 ]
	run -0 realpath "${BATS_TEST_TMPDIR}/current"
	[ "$output" = "$(realpath "${BATS_TEST_TMPDIR}/releases/3")" ]
}

@test "deployment from Git repository" {
	run_script "1" "$SIMPLE_DEPLOYMENT"
	run -0 stat "${BATS_TEST_TMPDIR}/current/tests"
	run -0 stat "${BATS_TEST_TMPDIR}/current/tests/symlinked-release.bats"
	run -0 stat "${BATS_TEST_TMPDIR}/current/deploy.py"
}
