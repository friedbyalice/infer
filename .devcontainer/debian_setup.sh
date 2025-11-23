set -ex

apt-get update

mkdir -p /usr/share/man/man1

apt-get install --yes --no-install-recommends \
  autoconf \
  automake \
  bzip2 \
  cmake \
  curl \
  g++ \
  gcc \
  libc6-dev \
  libgmp-dev \
  libmpfr-dev \
  libsqlite3-dev \
  sqlite3 \
  make \
  opam \
  openjdk-11-jdk-headless \
  patch \
  patchelf \
  pkg-config \
  python3 \
  python3-distutils \
  unzip \
  xz-utils \
  zlib1g-dev \
  rsync

rm -rf /var/lib/apt/lists/*

# # Disable sandboxing
# # Without this opam fails to compile OCaml for some reason. We don't need sandboxing inside a Docker container anyway.
opam init --reinit --bare --disable-sandboxing --yes --auto-setup

git config --global --add safe.directory /workspaces/infer

./build-infer.sh java --only-setup-opam

./build-infer.sh java

make devsetup

# build infer with make -j for the first time
make -j -C infer/src
