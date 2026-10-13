// Versions and constraints, matching how pub reads them.
import 'package:just_core_cli/just_core_cli.dart';
import 'package:test/test.dart';

Version v(String s) => Version.parse(s);
VersionConstraint c(String s) => VersionConstraint.parse(s);

void main() {
  group('Version', () {
    test('parses and prints', () {
      for (final s in [
        '0.0.0',
        '1.2.3',
        '1.2.3-dev.4',
        '1.2.3+5',
        '2.0.0-beta+exp.sha.5114f85',
      ]) {
        expect('${v(s)}', s);
      }
    });

    test('refuses what is not a version', () {
      for (final s in [
        '1',
        '1.2',
        '1.2.3.4',
        'v1.2.3',
        '01.2.3',
        '1.2.3-',
        '',
      ]) {
        expect(() => v(s), throwsFormatException, reason: s);
        expect(Version.tryParse(s), isNull);
      }
    });

    test('orders as semver 2.0 says', () {
      // The ordering example from semver.org, item 11.
      final ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
        '1.0.1',
        '1.1.0',
        '2.0.0',
      ].map(v).toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i - 1] < ordered[i],
          isTrue,
          reason: '${ordered[i - 1]} < ${ordered[i]}',
        );
      }
      final shuffled = [...ordered]..shuffle();
      expect(shuffled..sort(), ordered);
    });

    test('numbers too long for an int are kept, as pub keeps them', () {
      final stamped = v('1.0.0-dev.20261012083048123456789');
      expect('$stamped', '1.0.0-dev.20261012083048123456789');
      expect(v('1.0.0-dev.2') < stamped, isTrue, reason: 'numbers first');
      expect(v('1.0.0+20261012083048123456789'), isNotNull);
    });

    test('nextBreaking follows pub', () {
      expect('${v('1.2.3').nextBreaking}', '2.0.0');
      expect('${v('0.2.3').nextBreaking}', '0.3.0');
      expect('${v('0.0.3').nextBreaking}', '0.1.0');
    });
  });

  group('VersionConstraint', () {
    test('any', () {
      expect(c('any').allows(v('0.0.1')), isTrue);
      expect(c('any').isAny, isTrue);
    });

    test('exact', () {
      expect(c('1.2.3').allows(v('1.2.3')), isTrue);
      expect(c('1.2.3').allows(v('1.2.4')), isFalse);
    });

    test('caret', () {
      expect(c('^1.2.3').allows(v('1.9.0')), isTrue);
      expect(c('^1.2.3').allows(v('2.0.0')), isFalse);
      expect(c('^1.2.3').allows(v('1.2.2')), isFalse);
      expect(c('^0.2.3').allows(v('0.2.9')), isTrue);
      expect(c('^0.2.3').allows(v('0.3.0')), isFalse);
      expect(c('^0.0.3').allows(v('0.0.9')), isTrue);
      expect(c('^0.0.3').allows(v('0.1.0')), isFalse);
    });

    test('ranges', () {
      final r = c('>=1.0.0 <2.0.0');
      expect(r.allows(v('1.0.0')), isTrue);
      expect(r.allows(v('1.99.0')), isTrue);
      expect(r.allows(v('2.0.0')), isFalse);
      expect(r.allows(v('0.9.9')), isFalse);
      expect(c('>1.0.0').allows(v('1.0.0')), isFalse);
      expect(c('<=2.0.0').allows(v('2.0.0')), isTrue);
      expect(c('>=1.0.0<2.0.0').allows(v('1.5.0')), isTrue, reason: 'no space');
    });

    test('an exclusive upper bound excludes its pre-releases, as in pub', () {
      expect(c('^1.0.0').allows(v('2.0.0-dev.1')), isFalse);
      expect(c('>=1.0.0 <2.0.0').allows(v('2.0.0-dev.1')), isFalse);
      expect(c('>=2.0.0-dev.1 <2.0.0').allows(v('2.0.0-dev.3')), isTrue);
      expect(c('^1.0.0').allows(v('1.5.0-dev.1')), isTrue);
      // A bound with build metadata is taken as written, as pub does.
      expect(c('<2.0.0+1').allows(v('2.0.0-dev.1')), isTrue);
    });

    test('refuses what is not a constraint', () {
      for (final s in [
        '',
        'abc',
        '^1.2',
        '>=2.0.0 <1.0.0',
        '>=1.0.0 <1.0.0',
        '>1.0.0 <=1.0.0',
        '>=1.0.0 >=1.1.0',
        '~1.2.3',
      ]) {
        expect(() => c(s), throwsFormatException, reason: s);
      }
    });

    test('bestOf prefers releases', () {
      final versions = ['1.0.0', '1.2.0', '1.3.0-dev.1', '2.0.0'].map(v);
      expect('${c('^1.0.0').bestOf(versions)}', '1.2.0');
      expect('${c('>=1.3.0-dev.1 <2.0.0').bestOf(versions)}', '1.3.0-dev.1');
      expect(c('^3.0.0').bestOf(versions), isNull);
    });

    test('prints as written', () {
      for (final s in ['any', '1.2.3', '^1.2.3', '>=1.0.0 <2.0.0']) {
        expect('${c(s)}', s);
      }
    });
  });
}
