import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/services/sound_service.dart';
import 'package:zhuoluo/data/database/database.dart';
import 'package:zhuoluo/data/services/notification_service.dart';
import 'package:zhuoluo/features/profile/quadrant_page.dart';
import 'package:zhuoluo/main.dart';

import '../support/fake_notification_scheduler.dart';

void main() {
  testWidgets('四象限上下滚动不切页，明确横滑可切到我的', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    SoundService.enabled = false;
    NotificationService.instance.debugOverrideScheduler =
        FakeNotificationScheduler();
    addTearDown(
      () => NotificationService.instance.debugOverrideScheduler = null,
    );
    await db.ensureDefaultList();
    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZhuoluoApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('四象限'));
    await tester.pumpAndSettle();

    await tester.timedDrag(
      find.byType(QuadrantPage),
      const Offset(-110, 150),
      const Duration(milliseconds: 120),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );

    await tester.timedDrag(
      find.byType(QuadrantPage),
      const Offset(-130, 0),
      const Duration(milliseconds: 140),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
  });
}
