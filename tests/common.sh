setup_ssh() {
	rm -f /root/.ssh/id_ed25519
	ssh-keygen -t ed25519 -N "" -C "deploy-py-test" -f /root/.ssh/id_ed25519
	cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
	chmod 600 /root/.ssh/authorized_keys
	cat > /root/.ssh/config <<- EOF
		StrictHostKeyChecking no
		UserKnownHostsFile /dev/null
		LogLevel QUIET
	EOF
	chmod 600 /root/.ssh/config
}
