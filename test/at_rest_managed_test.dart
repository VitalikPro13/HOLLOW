/// `AtRest.isManaged` decides whether a file is ciphertext under the data root
/// (only our own pipe may read it) or a file the person picked (a platform
/// decoder may open it). It resolves the path the way Rust's
/// `under_data_root` does, and an answer it cannot work out counts as managed.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory base;
  late String root;

  setUp(() {
    base = Directory.systemTemp.createTempSync('hollow_managed');
    root = p.join(base.path, 'root');
    Directory(p.join(root, 'files')).createSync(recursive: true);
    Directory(p.join(base.path, 'outside')).createSync();
    File(p.join(root, 'files', 'a.mp4')).writeAsBytesSync([1]);
    File(p.join(base.path, 'outside', 'b.mp4')).writeAsBytesSync([2]);
    overrideHollowDataDir(root);
  });

  tearDown(() {
    try {
      base.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a_file_under_the_root_is_managed_and_one_beside_it_is_not', () {
    expect(AtRest.isManaged(p.join(root, 'files', 'a.mp4')), isTrue);
    expect(AtRest.isManaged(p.join(base.path, 'outside', 'b.mp4')), isFalse);
  });

  test('dot_dot_cannot_dress_an_outside_file_as_managed', () {
    final climbed = p.join(root, 'files', '..', '..', 'outside', 'b.mp4');
    expect(AtRest.isManaged(climbed), isFalse);
  });

  test('a_managed_file_named_through_dot_dot_stays_managed', () {
    final around = p.join(root, 'files', '..', 'files', 'a.mp4');
    expect(AtRest.isManaged(around), isTrue);
  });

  test('a_symlinked_data_root_still_owns_its_files', () {
    final alias = p.join(base.path, 'alias');
    Link(alias).createSync(root);
    overrideHollowDataDir(alias);
    expect(AtRest.isManaged(p.join(root, 'files', 'a.mp4')), isTrue);
    expect(AtRest.isManaged(p.join(alias, 'files', 'a.mp4')), isTrue);
  });

  test('a_link_out_of_the_root_leads_outside', () {
    final out = p.join(root, 'out');
    Link(out).createSync(p.join(base.path, 'outside'));
    expect(AtRest.isManaged(p.join(out, 'b.mp4')), isFalse);
  });

  test('a_path_that_cannot_be_resolved_counts_as_managed', () {
    expect(AtRest.isManaged('${root}x\u0000/a.mp4'), isTrue);
  });
}
