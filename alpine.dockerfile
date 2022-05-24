FROM alpine:latest

ENV PATH=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin
ENV SVDIR=/etc/service

RUN apk add \
	bash \
	openssh-server \
	openssh-client \
	nano \
	rsync \
	git \
	python3 \
	ncurses \
	runit

COPY tests/service /etc/service

ENTRYPOINT ["/sbin/runsvdir", "-P", "/etc/service"]
