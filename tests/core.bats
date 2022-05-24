bats_require_minimum_version 1.5.0

load common.sh

run_script() {
	{
cat << EOF
#!/usr/bin/env python3
from deploy import Deployment, Skip
deploy = Deployment(targets={
    "localhost": {},
    "root@localhost": {},
})
EOF
		cat
		echo
		echo "deploy.run()"
	} > "$TEST_SCRIPT"
	chmod +x "$TEST_SCRIPT"
	run -0 "$TEST_SCRIPT"
}

setup_file() {
	setup_ssh
}

setup() {
	mkdir -p "$BATS_TEST_TMPDIR"
	export PYTHONPATH="/test"
	export TEST_SCRIPT="${BATS_TEST_TMPDIR}/script.py"
	declare i
	for i in $(seq 20); do
		sleep 0.01
		nc -z -w 1 localhost 22 || continue
		break
	done
}

teardown() {
	rm -rf "$BATS_TEST_TMPDIR"
}

@test "simple echo" {
run_script << EOF
@deploy.task()
def task(target):
		target.run(["echo", "Hello world"])
EOF
}

@test "simultaneous execution" {
run_script << "EOF"
from time import sleep
@deploy.task()
def task(target):
		target.run(f"touch parallel-test-{target.name}")
		sleep(0.01)
		r = target.run("ls -1 parallel-test-*").stdout.rstrip().split("\n")
		assert len(r) == 2
EOF
}

@test "changing directory" {
	mkdir -p "${BATS_TEST_TMPDIR}/test"
run_script << EOF
@deploy.task(directory="${BATS_TEST_TMPDIR}")
def task1(target):
	target.run(["touch", f"test-{target.name}"])

@deploy.task()
def task2(target):
	target.cd("${BATS_TEST_TMPDIR}/test")
	target.run(["touch", f"test-{target.name}"])
EOF
	[ -e "${BATS_TEST_TMPDIR}/test-localhost" ]
	[ -e "${BATS_TEST_TMPDIR}/test/test-localhost" ]
}

@test "selecting target" {
run_script << EOF
@deploy.task(targets=["localhost"])
def task(target):
		target.run(["touch", f"${BATS_TEST_TMPDIR}/test-{target.name}"])
EOF
	[ -e "${BATS_TEST_TMPDIR}/test-localhost" ]
}

@test "user visible output" {
	declare text="text-visible-to-end-user"
run_script << EOF
@deploy.task()
def t(target):
		return target.run("echo ${text}").stdout
EOF
	if ! echo "$output" | grep "$text" >/dev/null; then
		echo "Failed to find \"${text}\" in output"
		return 1
	fi
}

@test "facts usage" {
run_script << EOF
@deploy.task()
def t1(target):
		target.facts["t1"] = target.name

@deploy.task()
def t2(target):
		assert target.facts["t1"] == target.name

@deploy.task(targets=["localhost"])
def t3(target):
		print(deploy.targets)
		for target in deploy.targets:
				assert target.name == target.facts["t1"]
EOF
}

@test "copying files" {
run_script << EOF
@deploy.task(targets=["localhost"], directory="${BATS_TEST_TMPDIR}")
def t(target):
		target.run(["mkdir", "test"])
		target.copy(["deploy.py", "tests"], "test", "/test")
EOF
	[ -e "${BATS_TEST_TMPDIR}/test/deploy.py" ]
	[ -e "${BATS_TEST_TMPDIR}/test/tests/core.bats" ]
}

@test "skipping task" {
	declare reason="visible-skip-reason-messsage"
run_script << EOF
@deploy.task(directory="${BATS_TEST_TMPDIR}")
def t(target):
		if target.name == "localhost":
				raise Skip("${reason}")
		target.run(["touch", f"test-{target.name}"])
EOF
	if ! echo "$output" | grep "$reason" >/dev/null; then
		echo "Failed to find \"${reason}\" in output"
		return 1
	fi
	run -0 ls -1 "${BATS_TEST_TMPDIR}"/test-*
	[ "${#lines[@]}" -eq 1 ]
}
