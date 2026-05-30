set -ex

apt update
mkdir -p /usr/share/man/man1

apt install --yes \
  clang-19 \
  llvm-19 \
  llvm-19-dev \
  libmpfr-dev \
  libsqlite3-dev \
  ninja-build \
  opam \
  autoconf \
  automake \
  bzip2 \
  cmake \
  curl \
  libc6-dev \
  libgmp-dev \
  sqlite3 \
  make \
  openjdk-21-jdk-headless \
  patch \
  patchelf \
  pkg-config \
  python3 \
  unzip \
  xz-utils \
  zlib1g-dev \
  rsync \
  parallel

rm -rf /var/lib/apt/lists/*

# Disable sandboxing
# Without this opam fails to compile OCaml for some reason. We don't need sandboxing inside a Docker container anyway.
opam init --reinit --bare --disable-sandboxing --yes --auto-setup

git config --global --add safe.directory /workspaces/infer

./build-infer.sh --only-setup-opam

./facebook-clang-plugins/clang/src/prepare_clang_src.sh
CC=clang CXX=clang++ ./facebook-clang-plugins/clang/setup.sh --ninja --sequential-link
./build-infer.sh 

make devsetup

# build infer with make -j for the first time
make -j -C infer/src

echo 'export PATH="/workspaces/infer/infer/bin":$PATH' >> "/root/.bashrc"
echo 'export MANPATH="/workspaces/infer/infer/man":$MANPATH' >> "/root/.bashrc"
