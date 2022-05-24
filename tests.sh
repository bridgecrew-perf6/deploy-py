#!/usr/bin/env bash

set -euo pipefail -o errtrace
shopt -s nullglob inherit_errexit

BATS_URL="https://github.com/bats-core/bats-core/archive/20258549eef420fdadc513730283213714add058.tar.gz"
CONTAINER_NAME="deploy-py-test"
IMAGE_NAME=$CONTAINER_NAME
# Leave container by default
LEAVE_ENV=${LEAVE_ENV:-1}
TARGET_TEST="."
TARGET_IMAGE=""
TARGET_IMAGES="alpine debian centos"

on_error() {
	local \
		exit_code=$? \
		cmd=$BASH_COMMAND
	if [ "$LEAVE_ENV" != 1 ]; then
		local label
		for label in $TARGET_IMAGES; do
			docker rm -f "${CONTAINER_NAME}-${label}" >/dev/null || true
		done
	fi
	echo "Failing with code ${exit_code} at ${*} in command: ${cmd}" >&2
	exit "$exit_code"
}

build_images() {
	local label
	for label in $TARGET_IMAGES; do
		if [ -n "$TARGET_IMAGE" ] && [ "$label" != "$TARGET_IMAGE" ]; then
			continue
		fi
		if ! docker image inspect "${IMAGE_NAME}:${label}" &>/dev/null; then
			docker build -t "${IMAGE_NAME}:${label}" . -f "${label}.dockerfile"
		fi
	done
}

run_tests() {
	local label
	for label in $TARGET_IMAGES; do
		if [ -n "$TARGET_IMAGE" ] && [ "$label" != "$TARGET_IMAGE" ]; then
			continue
		fi
		echo "Running tests for ${label}..."
		if ! docker container inspect "${CONTAINER_NAME}-${label}" &>/dev/null; then
			docker run \
				--init \
				-d --name "${CONTAINER_NAME}-${label}" \
				-v "${CURRENT_DIR:-$(pwd)}:/test:ro" \
				"${IMAGE_NAME}:${label}" \
				>/dev/null
		fi
		local with_tty_option=''
		if [ -t 1 ]; then
			with_tty_option='-t'
		fi
		docker exec \
			$with_tty_option \
			"${CONTAINER_NAME}-${label}" \
			"/test/.bats/bin/bats" \
			--print-output-on-failure \
			"/test/tests/${TARGET_TEST}"
		docker rm -f "${CONTAINER_NAME}-${label}" >/dev/null
	done
}

download_bats() {
	if [ ! -d .bats ]; then
		mkdir .bats
		wget -q -O - "$BATS_URL" \
			| tar -C .bats --strip-components 1 -xzf -
	fi
}

main_help() {
cat << EOF
Options:
	-i|--image IMAGE       Container image to use. By default all images are used
	                       sequentially.
	-t|--target TARGET     Target test path.
EOF
}

main() {
	trap 'on_error ${BASH_SOURCE[0]}:${LINENO}' ERR
	while [ "$#" != 0 ]; do
		local option=$1; shift
		case "$option" in
		-t|--target)
			TARGET_TEST=$1; shift
		;;
		-i|--image)
			TARGET_IMAGE=$1; shift
		;;
		*)
			main_help
			exit
		;;
		esac
	done
	shellcheck "$0"
	download_bats
	build_images
	run_tests
}

main "$@"
