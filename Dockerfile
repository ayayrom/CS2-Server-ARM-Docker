#builder for the image
FROM debian:bookworm AS builder
SHELL ["/bin/bash", "-c"]

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y git curl python3 sudo cmake ninja-build pkg-config clang llvm lld nasm libsdl2-dev libepoxy-dev libssl-dev python3-dev libstdc++-12-dev squashfs-tools squashfuse qtbase5-dev qtdeclarative5-dev qt5-qmake

WORKDIR /tmp
RUN git clone --recurse-submodules --branch FEX-2601 --depth 1 https://github.com/FEX-Emu/FEX.git

WORKDIR /tmp/FEX
#CMAKE exclusive to ampere CPUs
RUN mkdir Build && cd Build && \
        CC=clang CXX=clang++ cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DUSE_LINKER=lld -DENABLE_LTO=True -DBUILD_TESTS=False -DENABLE_ASSERTIONS=False \
        -DCMAKE_C_FLAGS="-mcpu=neoverse-n1 -O3 -fno-math-errno" -DCMAKE_CXX_FLAGS="-mcpu=neoverse-n1 -O3 -fno-math-errno" -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=True \
        -G Ninja .. && ninja && ninja install
# might downgrade to -O2 if enough issues come up

#actual image properties
FROM debian:bookworm-slim
SHELL ["/bin/bash", "-c"]

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y curl python3 sudo locales tzdata unzip libsdl2-2.0-0 libepoxy0 libssl3 libstdc++6 squashfs-tools squashfuse libqt5widgets5 libqt5qml5 && rm -rf /var/lib/apt/lists/*

RUN echo "de_DE.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen de_DE.UTF-8
ENV LANG=de_DE.UTF-8
ENV LANGUAGE=de_DE:de
ENV LC_ALL=de_DE.UTF-8
ENV TZ=Europe/Berlin
RUN ln -snf /usr/share/zoneinfo/Europe/Berlin /etc/localtime && echo Europe/Berlin > /etc/timezone

COPY --from=builder /usr/bin/FEX* /usr/bin/

RUN useradd -m steam

COPY --chown=steam:steam --chmod=755 init-server.sh /home/steam/init-server.sh

USER steam

WORKDIR /home/steam/Steam
RUN curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf -

WORKDIR /home/steam
ENTRYPOINT ["/bin/bash"]
