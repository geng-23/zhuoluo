import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/utils/task_title.dart';
import 'package:zhuoluo/data/services/chinese_date_parser.dart';
import 'package:zhuoluo/data/services/rrule_expander.dart';

void main() {
  group('ChineseDateParser', () {
    final base = DateTime(2026, 8, 5); // 周三

    void expectDate(String input, DateTime? expected, {String? rrule}) {
      final r = ChineseDateParser.instance.parse(input, now: base);
      expect(r.date, expected,
          reason: 'input="$input" date=${r.date} expected=$expected');
      if (rrule != null) {
        expect(r.rrule, rrule, reason: 'input="$input"');
      }
    }

    test('今天/明天/后天', () {
      expectDate('今天', DateTime(2026, 8, 5));
      expectDate('明天', DateTime(2026, 8, 6));
      expectDate('后天', DateTime(2026, 8, 7));
      expectDate('昨天', DateTime(2026, 8, 4));
    });

    test('周几', () {
      expectDate('周五', DateTime(2026, 8, 7));
      expectDate('周三', DateTime(2026, 8, 5));
      expectDate('下周一', DateTime(2026, 8, 10));
    });

    test('具体日期', () {
      expectDate('8月10日', DateTime(2026, 8, 10));
      expectDate('9月1日', DateTime(2026, 9, 1));
    });

    test('相对时间', () {
      expectDate('3天后', DateTime(2026, 8, 8));
      expectDate('月底', DateTime(2026, 8, 31));
    });

    test('时间', () {
      final r = ChineseDateParser.instance.parse('下午3点', now: base);
      expect(r.time?.hour, 15);
      final r2 = ChineseDateParser.instance.parse('明天早上9点', now: base);
      expect(r2.date, DateTime(2026, 8, 6));
      expect(r2.time?.hour, 9);
    });

    test('重复规则', () {
      expectDate('每天', null, rrule: 'FREQ=DAILY');
      expectDate('每周五', DateTime(2026, 8, 7), rrule: 'FREQ=WEEKLY;BYDAY=FR');
      expectDate('每3天', null, rrule: 'FREQ=DAILY;INTERVAL=3');
    });

    test('组合', () {
      final r = ChineseDateParser.instance.parse('明天下午3点交报告', now: base);
      expect(r.date, DateTime(2026, 8, 6));
      expect(r.time?.hour, 15);
      expect(r.matched, true);
    });

    test('无时间词', () {
      final r = ChineseDateParser.instance.parse('随便记一下', now: base);
      expect(r.matched, false);
    });

    test('下午3点到5点 → 15:00-17:00（继承下午时段）', () {
      final r = ChineseDateParser.instance.parse('下午3点到5点', now: base);
      expect(r.time!.hour, 15);
      expect(r.endTime!.hour, 17,
          reason: '结束应为当天 17:00 而非次日凌晨 05:00');
    });

    test('晚上11点到1点 → 23:00-01:00（跨午夜仍正确）', () {
      final r = ChineseDateParser.instance.parse('晚上11点到1点', now: base);
      expect(r.time!.hour, 23);
      expect(r.endTime!.hour, 1, reason: '次日凌晨 1 点');
    });

    test('显式结束时段优先（早上9点到下午2点）', () {
      final r = ChineseDateParser.instance.parse('早上9点到下午2点', now: base);
      expect(r.time!.hour, 9);
      expect(r.endTime!.hour, 14);
    });

    test('结束支持点半（下午3点到4点半）', () {
      final r = ChineseDateParser.instance.parse('下午3点到4点半', now: base);
      expect(r.time!.hour, 15);
      expect(r.endTime!.hour, 16);
      expect(r.endTime!.minute, 30);
    });

    test('下3点 → 15:00', () {
      final r = ChineseDateParser.instance.parse('下3点开会', now: base);
      expect(r.time!.hour, 15);
      final r2 = ChineseDateParser.instance.parse('下3点半', now: base);
      expect(r2.time!.hour, 15);
      expect(r2.time!.minute, 30);
    });

    test('每N周补 BYDAY=起始星期；每2周三显式星期三', () {
      // base 2026-08-05 周三
      final r = ChineseDateParser.instance.parse('每2周', now: base);
      expect(r.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE');
      final r2 = ChineseDateParser.instance.parse('每2周三', now: base);
      expect(r2.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE');
      expect(r2.date, DateTime(2026, 8, 5), reason: '当天即周三');
      final r3 = ChineseDateParser.instance.parse('每2周六', now: base);
      expect(r3.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=SA');
      expect(r3.date, DateTime(2026, 8, 8), reason: '本周六 8/8');
    });

    test('每周一 → BYDAY=MO（死代码删除后仍正常）', () {
      final r = ChineseDateParser.instance.parse('每周一', now: base);
      expect(r.rrule, 'FREQ=WEEKLY;BYDAY=MO');
      expect(r.date, DateTime(2026, 8, 10), reason: '本周一已过取下周');
    });

    test('下个月月底 → 下月最后一天（不受当月月底抢占）', () {
      final r = ChineseDateParser.instance.parse('下个月月底交报告', now: base);
      expect(r.date, DateTime(2026, 9, 30));
      final r2 = ChineseDateParser.instance.parse('月底', now: base);
      expect(r2.date, DateTime(2026, 8, 31));
    });

    test('裸"3天"不解析，仅"3天后/3天之后"为相对日期', () {
      final r = ChineseDateParser.instance.parse('3天交报告', now: base);
      expect(r.matched, isFalse);
      expect(r.date, isNull);
      final r2 = ChineseDateParser.instance.parse('3天后交报告', now: base);
      expect(r2.date, DateTime(2026, 8, 8));
      final r3 = ChineseDateParser.instance.parse('3天之后', now: base);
      expect(r3.date, DateTime(2026, 8, 8));
    });

    test('晚上12点为午夜 00:00', () {
      final r = ChineseDateParser.instance.parse('晚上12点', now: base);
      expect(r.time!.hour, 0);
      final r2 = ChineseDateParser.instance.parse('晚上12点半', now: base);
      expect(r2.time!.hour, 0);
      expect(r2.time!.minute, 30);
      final r3 = ChineseDateParser.instance.parse('中午12点', now: base);
      expect(r3.time!.hour, 12, reason: '中午12点仍是正午');
      final r4 = ChineseDateParser.instance.parse('晚上12点到1点', now: base);
      expect(r4.time!.hour, 0);
      expect(r4.endTime!.hour, 1, reason: '午夜到凌晨1点');
    });

    test('中文数字时间：五点/五点半/两点/七点二十分', () {
      final r = ChineseDateParser.instance.parse('五点开会', now: base);
      expect(r.time!.hour, 5);
      final r2 = ChineseDateParser.instance.parse('五点半', now: base);
      expect(r2.time!.hour, 5);
      expect(r2.time!.minute, 30);
      final r3 = ChineseDateParser.instance.parse('下午三点', now: base);
      expect(r3.time!.hour, 15);
      final r4 = ChineseDateParser.instance.parse('晚上十二点', now: base);
      expect(r4.time!.hour, 0, reason: '晚上十二点 = 午夜');
      final r5 = ChineseDateParser.instance.parse('七点二十分', now: base);
      expect(r5.time!.hour, 7);
      expect(r5.time!.minute, 20);
      final r6 = ChineseDateParser.instance.parse('两点半', now: base);
      expect(r6.time!.hour, 2);
      final r7 = ChineseDateParser.instance.parse('十一点', now: base);
      expect(r7.time!.hour, 11);
      final r8 = ChineseDateParser.instance.parse('二十二点', now: base);
      expect(r8.time!.hour, 22, reason: '两位中文数字整点');
    });

    test('中文数字结束时间：下午三点到五点（继承时段）', () {
      final r = ChineseDateParser.instance.parse('下午三点到五点', now: base);
      expect(r.time!.hour, 15);
      expect(r.endTime!.hour, 17);
      final r2 = ChineseDateParser.instance.parse('晚上十一点到一点', now: base);
      expect(r2.time!.hour, 23);
      expect(r2.endTime!.hour, 1, reason: '跨午夜仍正确');
    });

    test('中文数字重复规则：每一周/每两周/每两个月/每月五号', () {
      final r = ChineseDateParser.instance.parse('每一周', now: base);
      expect(r.rrule, 'FREQ=WEEKLY;INTERVAL=1;BYDAY=WE', reason: 'base 为周三');
      final r2 = ChineseDateParser.instance.parse('每两周', now: base);
      expect(r2.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE');
      final r3 = ChineseDateParser.instance.parse('每两个月', now: base);
      expect(r3.rrule, 'FREQ=MONTHLY;INTERVAL=2');
      final r4 = ChineseDateParser.instance.parse('每月五号', now: base);
      expect(r4.rrule, 'FREQ=MONTHLY;BYMONTHDAY=5');
      final r5 = ChineseDateParser.instance.parse('每两天', now: base);
      expect(r5.rrule, 'FREQ=DAILY;INTERVAL=2');
      final r6 = ChineseDateParser.instance.parse('每两周三', now: base);
      expect(r6.rrule, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE');
    });

    test('中文数字日期：三天后/八月十日/五号/下个月五号', () {
      final r = ChineseDateParser.instance.parse('三天后交报告', now: base);
      expect(r.date, DateTime(2026, 8, 8));
      final r2 = ChineseDateParser.instance.parse('八月十日', now: base);
      expect(r2.date, DateTime(2026, 8, 10));
      final r3 = ChineseDateParser.instance.parse('五号', now: base);
      expect(r3.date, DateTime(2026, 8, 5));
      final r4 = ChineseDateParser.instance.parse('下个月五号', now: base);
      expect(r4.date, DateTime(2026, 9, 5));
      final r5 = ChineseDateParser.instance.parse('十一月五日', now: base);
      expect(r5.date, DateTime(2026, 11, 5));
      final r6 = ChineseDateParser.instance.parse('十天后', now: base);
      expect(r6.date, DateTime(2026, 8, 15));
    });
  });

  group('extractTaskTitle 同步（P1-D）', () {
    test('每2周三整体切除', () {
      expect(extractTaskTitle('每2周三跑步'), '跑步');
    });
    test('下个月月底整体切除', () {
      expect(extractTaskTitle('下个月月底交报告'), '交报告');
    });
    test('下3点', () {
      expect(extractTaskTitle('下3点开会'), '开会');
    });
    test('裸3天保留', () {
      expect(extractTaskTitle('3天交报告'), '3天交报告');
    });
    test('下午3点到5点整体切除', () {
      expect(extractTaskTitle('下午3点到5点交报告'), '交报告');
    });
    test('中文数字标题同步', () {
      expect(extractTaskTitle('五点跑步'), '跑步');
      expect(extractTaskTitle('下午三点交报告'), '交报告');
      expect(extractTaskTitle('每一周健身'), '健身');
      expect(extractTaskTitle('每两周健身'), '健身');
      expect(extractTaskTitle('每两个月体检'), '体检');
      expect(extractTaskTitle('八月十日交报告'), '交报告');
    });
  });

  group('RruleService', () {
    final service = RruleService.instance;

    test('daily', () {
      final hits = service.hitsOn(
          'FREQ=DAILY', DateTime(2026, 8, 3), DateTime(2026, 8, 5));
      expect(hits, true);
      final miss = service.hitsOn(
          'FREQ=DAILY', DateTime(2026, 8, 3), DateTime(2026, 8, 4));
      expect(miss, true);
    });

    test('weekly byday', () {
      final hit = service.hitsOn('FREQ=WEEKLY;BYDAY=FR', DateTime(2026, 8, 3),
          DateTime(2026, 8, 7)); // 周五
      expect(hit, true);
      final miss = service.hitsOn('FREQ=WEEKLY;BYDAY=FR', DateTime(2026, 8, 3),
          DateTime(2026, 8, 6)); // 周四
      expect(miss, false);
    });

    test('interval weekly', () {
      final hit = service.hitsOn(
          'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO',
          DateTime(2026, 8, 3),
          DateTime(2026, 8, 17)); // 两周后周一
      expect(hit, true);
      final miss = service.hitsOn(
          'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO',
          DateTime(2026, 8, 3),
          DateTime(2026, 8, 10)); // 一周后周一
      expect(miss, false);
    });

    test('monthly', () {
      final hit = service.hitsOn(
          'FREQ=MONTHLY', DateTime(2026, 8, 10), DateTime(2026, 9, 10));
      expect(hit, true);
      final miss = service.hitsOn(
          'FREQ=MONTHLY', DateTime(2026, 8, 10), DateTime(2026, 9, 11));
      expect(miss, false);
    });

    test('expand daily', () {
      final list = service.expand(DateTime(2026, 8, 3), 'FREQ=DAILY', limit: 5);
      expect(list.length, 5);
      expect(list.first, DateTime(2026, 8, 3));
    });

    test('until 边界', () {
      final hit = service.hitsOn('FREQ=DAILY;UNTIL=20260810',
          DateTime(2026, 8, 3), DateTime(2026, 8, 10));
      expect(hit, true);
      final miss = service.hitsOn('FREQ=DAILY;UNTIL=20260810',
          DateTime(2026, 8, 3), DateTime(2026, 8, 11));
      expect(miss, false);
    });

    test('count 展开截断', () {
      final list = service.expand(
          DateTime(2026, 8, 3), 'FREQ=DAILY;COUNT=3', limit: 100);
      expect(list.length, 3);
      expect(list.last, DateTime(2026, 8, 5));
    });

    test('count 命中边界', () {
      final inCount = service.hitsOn('FREQ=DAILY;COUNT=3',
          DateTime(2026, 8, 3), DateTime(2026, 8, 5));
      expect(inCount, true, reason: '第 3 次实例应命中');
      final outCount = service.hitsOn('FREQ=DAILY;COUNT=3',
          DateTime(2026, 8, 3), DateTime(2026, 8, 6));
      expect(outCount, false, reason: '第 4 次实例不应命中');
    });

    test('weekly 全选 7 天（显式 BYDAY）每天命中', () {
      const rrule = 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU';
      final start = DateTime(2026, 8, 3); // 周一
      for (var d = 0; d < 7; d++) {
        expect(service.hitsOn(rrule, start, start.add(Duration(days: d))), true,
            reason: '第 $d 天应命中');
      }
      final list = service.expand(start, rrule, limit: 14);
      expect(list.length, 14);
    });

    test('monthly 无效日（31 号的小月）不命中且不产生进位', () {
      final start = DateTime(2026, 8, 31);
      final list = service.expand(start, 'FREQ=MONTHLY;BYMONTHDAY=31',
          from: DateTime(2026, 9, 1), to: DateTime(2026, 11, 30), limit: 100);
      // 9 月无 31 号跳过，10/31、11/31（进位被过滤）
      final days = list.map((d) => d.day).toSet();
      expect(days, {31});
      final nov = list.where((d) => d.month == 11);
      expect(nov.length, 0, reason: '11 月 31 号自动进位到 12 月应被过滤');
    });

    test('expand 窗口：老任务未来窗口仍可展开', () {
      // start 在 2 年前，窗口取最近几天
      final start = DateTime(2024, 8, 3);
      final list = service.expand(start, 'FREQ=DAILY',
          from: DateTime(2026, 8, 5),
          to: DateTime(2026, 8, 7),
          limit: 100);
      expect(list, [
        DateTime(2026, 8, 5),
        DateTime(2026, 8, 6),
        DateTime(2026, 8, 7),
      ]);
    });
  });
}
