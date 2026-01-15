# Maintainer: GhostKellz <ghost@ghostkellz.sh>
pkgname=nvshader
pkgver=0.1.1
pkgrel=1
pkgdesc="NVIDIA Shader Cache Manager - P2P sharing, pre-warming, and optimization"
arch=('x86_64')
url="https://github.com/ghostkellz/nvshader"
license=('MIT')
depends=('glibc')
makedepends=('zig>=0.16')
optdepends=(
    'nvidia-utils: NVIDIA GPU metrics and detection'
    'steam: Steam game detection and cache paths'
    'fossilize: Shader pre-warming via fossilize_replay'
    'lutris: Lutris game detection'
    'heroic-games-launcher: Heroic/Epic game detection'
)
provides=('libnvshader.so')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "$pkgname-$pkgver"
    zig build -Doptimize=ReleaseFast -Dlinkage=dynamic
}

package() {
    cd "$pkgname-$pkgver"

    # CLI binary
    install -Dm755 zig-out/bin/nvshader "$pkgdir/usr/bin/nvshader"

    # Shared library for FFI
    install -Dm755 zig-out/lib/libnvshader.so "$pkgdir/usr/lib/libnvshader.so"

    # C header for development
    install -Dm644 include/nvshader.h "$pkgdir/usr/include/nvshader.h"

    # Documentation
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
