#!/bin/bash
set -euo pipefail

helpers_file="assignment-autotest/test/shared/script-helpers"
docker_run_test_file="assignment-autotest/docker/run-test.sh"

if [ ! -f "${helpers_file}" ]; then
    echo "Missing ${helpers_file}"
    exit 1
fi

if [ -f "${docker_run_test_file}" ]; then
    sed -i 's/conf\/requres-ssh-key/conf\/requires-ssh-key/g' "${docker_run_test_file}"
fi

marker="# A4_CI_QEMU_SSH_OVERRIDE"
if grep -q "${marker}" "${helpers_file}"; then
    echo "CI SSH override already present in ${helpers_file}"
    exit 0
fi

cat >> "${helpers_file}" <<'EOF'

# A4_CI_QEMU_SSH_OVERRIDE
QEMU_SSH_OPTS="-o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 -o ConnectTimeout=3"

ssh_cmd() {
	cmd=$1
	sshpass -p 'root' ssh ${QEMU_SSH_OPTS} root@localhost -p 10022 ${cmd}
}

add_to_rootfs() {
	path_to_file=$1
	rootfs_location=$2
	echo "adding ${path_to_file} to the rootfs at ${rootfs_location}"
	sshpass -p 'root' scp ${QEMU_SSH_OPTS} -P 10022 ${path_to_file} root@localhost:${rootfs_location}
}

wait_for_qemu(){
	ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "[localhost]:10022"
	echo "Waiting for qemu to startup"
	max_wait_seconds=${QEMU_SSH_MAX_WAIT_SECONDS:-240}
	start_time=$(date +%s)
	local wait_for_ssh_startup="true"
	while [ ${wait_for_ssh_startup} == "true" ]; do
		tmpfile=`mktemp`
		ssh_cmd "exit" > ${tmpfile} 2>&1
		rc=$?
		if [ ${rc} -eq 0 ]; then
			echo "SSH login successful, waiting 40 additional seconds for process startup"
			sleep 40
			wait_for_ssh_startup="false"
		else
			now=$(date +%s)
			elapsed=$((now - start_time))
			if [ ${elapsed} -ge ${max_wait_seconds} ]; then
				echo "Timed out waiting for qemu SSH after ${elapsed} seconds"
				echo "Last SSH attempt output:"
				cat ${tmpfile}
				rm -f ${tmpfile}
				return 1
			fi
			sleep 5
			echo "still waiting for qemu to startup... last attempt returned ${rc} with output"
			cat ${tmpfile}
		fi
		rm -f ${tmpfile}
	done
}

validate_qemu(){
	echo "Executing runqemu.sh in background"
	./runqemu.sh &
	wait_for_qemu
	rc=$?
	if [ ${rc} -ne 0 ]; then
		add_validate_error "Timed out waiting for qemu SSH startup"
		return ${rc}
	fi
}

validate_assignment2_checks() {
	script_dir=${1}
	executable_path=${2}
	sshpass -p 'root' scp ${QEMU_SSH_OPTS} -P 10022 ${script_dir}/assignment-1-test.sh root@localhost:${executable_path}
	sshpass -p 'root' scp ${QEMU_SSH_OPTS} -P 10022 ${script_dir}/script-helpers root@localhost:${executable_path}
	ssh_cmd "${executable_path}/assignment-1-test.sh"
	rc=$?
	if [ ${rc} -ne 0 ]; then
		add_validate_error "Failed to run assignment-1-test script inside qemu"
	fi
}
EOF

echo "Applied CI SSH override to ${helpers_file}"
