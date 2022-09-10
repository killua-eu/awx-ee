ARG EE_BASE_IMAGE=quay.io/ansible/ansible-runner:latest
ARG EE_BUILDER_IMAGE=quay.io/ansible/ansible-builder:latest

FROM $EE_BASE_IMAGE as galaxy
ARG ANSIBLE_GALAXY_CLI_COLLECTION_OPTS=
ARG ANSIBLE_GALAXY_CLI_ROLE_OPTS=
USER root

RUN git lfs install
ENV GO_DOWNLOAD_URI="https://go.dev/dl/go1.18.4.linux-amd64.tar.gz" \
    PATH="/root/.local/bin:/root/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:/var/lib/snapd/snap/bin:/sbin:/usr/local/go/bin:/opt/go/bin" \
    PKG_CONFIG_PATH="/usr/local/lib" \
    GOROOT=/usr/local/go \
    GOPATH=/opt/go \
    CGO_CFLAGS="-I/root/go/deps/raft/include/ -I/root/go/deps/dqlite/include/" \
    CGO_LDFLAGS="-L/root/go/deps/raft/.libs -L/root/go/deps/dqlite/.libs/" \
    LD_LIBRARY_PATH="/root/go/deps/raft/.libs/:/root/go/deps/dqlite/.libs/" \
    CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)"

WORKDIR /tmp
USER root
RUN cd /tmp && mkdir -p "${GOPATH}" && wget "${GO_DOWNLOAD_URI}" && pwd && ls -ahl . && tar -C /usr/local -xzf ./go1*tar.gz && rm ./go1*tar.gz
ADD ./lxc ./lxc
USER root
RUN cd ./lxc && ./autogen.sh \ && ./configure --prefix=/usr \ && make \ && make install \ && libtool --finish /usr/local/lib \ && ldconfig -n /usr/local/lib
ADD ./raft ./raft
USER root
RUN cd ./raft && autoreconf -i \ && ./configure --prefix=/usr \ && make  \ && make install \ && libtool --finish /usr/local/lib \ && ldconfig -n /usr/local/lib
ADD ./dqlite ./dqlite
USER root
RUN cd ./dqlite \ && autoreconf -i \ && ./configure --prefix=/usr \ && make \ && make install
ADD ./lxd ./lxd
RUN cd ./lxd \ && make deps \ && make



ADD _build /build
WORKDIR /build

RUN ansible-galaxy role install $ANSIBLE_GALAXY_CLI_ROLE_OPTS -r requirements.yml --roles-path "/usr/share/ansible/roles"
RUN ANSIBLE_GALAXY_DISABLE_GPG_VERIFY=1 ansible-galaxy collection install $ANSIBLE_GALAXY_CLI_COLLECTION_OPTS -r requirements.yml --collections-path "/usr/share/ansible/collections"

FROM $EE_BUILDER_IMAGE as builder

COPY --from=galaxy /usr/share/ansible /usr/share/ansible

ADD _build/bindep.txt bindep.txt
RUN ansible-builder introspect --sanitize --user-bindep=bindep.txt --write-bindep=/tmp/src/bindep.txt --write-pip=/tmp/src/requirements.txt
RUN assemble

FROM $EE_BASE_IMAGE
USER root

COPY --from=galaxy /usr/share/ansible /usr/share/ansible

COPY --from=builder /output/ /output/
RUN /output/install-from-bindep && rm -rf /output/wheels
RUN alternatives --set python /usr/bin/python3
COPY --from=quay.io/ansible/receptor:devel /usr/bin/receptor /usr/bin/receptor
RUN mkdir -p /var/run/receptor
ADD run.sh /run.sh
CMD /run.sh
USER root
LABEL ansible-execution-environment=true
