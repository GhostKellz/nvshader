# Maintainer: Your Name <your@email.com>
pkgname=nvshader
pkgver=0.1.0
pkgrel=1
pkgdesc="NVIDIA Shader Cache Management & Optimization for Linux Gaming"
arch=('x86_64')
url="https://github.com/yourname/nvshader"
license=('MIT')
depends=('glibc')
makedepends=('zig>=0.16')
optdepends=(
    'nvidia-utils: NVIDIA GPU support'
    'steam: Steam integration'
    'fossilize: Shader pre-warming'
)
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "$pkgname-$pkgver"
    zig build -Doptimize=ReleaseFast
}

package() {
    cd "$pkgname-$pkgver"
    install -Dm755 zig-out/bin/nvshader "$pkgdir/usr/bin/nvshader"
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
