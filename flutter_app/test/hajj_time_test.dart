import 'package:flutter_test/flutter_test.dart';

import 'package:ain_alhamla/l10n/strings.dart';
import 'package:ain_alhamla/services/hajj_time.dart';

void main() {
  test('التاريخ الهجري: يوم عرفة 1447 = 26 مايو 2026', () {
    expect(HajjTime.hijri(DateTime(2026, 5, 26)), [1447, 12, 9]);
    expect(HajjTime.hijri(DateTime(2026, 5, 27)), [1447, 12, 10]);
  });

  test('اتجاه القبلة من الرياض ومن منى', () {
    expect(HajjTime.qibla(24.7136, 46.6753), inInclusiveRange(242, 246));
    expect(HajjTime.qibla(21.4133, 39.8933), inInclusiveRange(275, 282));
  });

  test('مواقيت مكة يوم عرفة 1447 تقريبية ومرتبة', () {
    final t = HajjTime.prayerTimes(DateTime(2026, 5, 26));
    expect(HajjTime.clock(t['dhuhr']!), '12:18');
    for (var i = 1; i < HajjTime.prayers.length; i++) {
      expect(t[HajjTime.prayers[i]]!.isAfter(t[HajjTime.prayers[i - 1]]!), true);
    }
  });

  test('نصوص «حجّي» متوفرة بالأربع لغات', () {
    const keys = ['h_title', 'h_TAWAF', 'h_JAMRAH_AQABA', 'h_wellness_q', 'h_cat_PASSPORT', 'h_lost_FOUND', 'h_day_9', 'h_isha'];
    for (final lang in S.supported) {
      for (final k in keys) {
        expect(S(lang).t(k) != k, true, reason: '$lang/$k');
      }
    }
  });
}
