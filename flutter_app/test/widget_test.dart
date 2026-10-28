import 'package:flutter_test/flutter_test.dart';

import 'package:ain_alhamla/l10n/strings.dart';

void main() {
  test('كل النصوص متوفرة بالأربع لغات', () {
    for (final lang in S.supported) {
      final s = S(lang);
      expect(s.t('app_name').isNotEmpty, true);
      expect(s.t('checked_of', {'a': 3, 'b': 5}).contains('3'), true);
    }
    expect(S.ar('phr_lost').contains('تائه'), true);
    expect(S.isRtl('ur'), true);
    expect(S.isRtl('id'), false);
  });
}
