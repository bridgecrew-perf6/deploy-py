FROM centos:7

ENV PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin

RUN yum install -y \
	bash \
	openssh-server \
	openssh-clients \
	git \
	nano \
	rsync \
	python3

COPY tests/service /etc/service

ENTRYPOINT ["/etc/service/sshd/run"]
