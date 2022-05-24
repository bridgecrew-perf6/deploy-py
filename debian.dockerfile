FROM debian:stable

ENV PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin
ENV SVDIR=/etc/service

RUN apt-get update && apt-get install -y --no-install-recommends \
	bash \
	openssh-server \
	openssh-client \
	nano \
	git \
	rsync \
	python3 \
	runit

ENTRYPOINT ["/usr/bin/runsvdir", "-P", "/etc/service"]
