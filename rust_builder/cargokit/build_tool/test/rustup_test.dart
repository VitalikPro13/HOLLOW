// `rustup toolchain list` parsing (lib/src/rustup.dart). Run it with
// `dart run test/rustup_test.dart`, like shared_build_test.dart.
import 'package:build_tool/src/rustup.dart';
import 'package:test/test.dart';

void main() {
  test('an installed exact version counts, so it is not installed again', () {
    const out = 'stable-aarch64-apple-darwin (active, default)\n'
        '1.99.1-aarch64-apple-darwin\n'
        'nightly-2026-01-01-aarch64-apple-darwin\n';
    expect(toolchainNames(out), [
      'stable-aarch64-apple-darwin',
      '1.99.1-aarch64-apple-darwin',
      'nightly-2026-01-01-aarch64-apple-darwin',
    ]);
  });

  test('custom and partial names are not toolchains we asked for', () {
    const out = 'my-linked-toolchain\n1.99-aarch64-apple-darwin\n\n';
    expect(toolchainNames(out), isEmpty);
  });
}
