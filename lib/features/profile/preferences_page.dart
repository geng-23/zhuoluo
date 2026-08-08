import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:zhuoluo/core/providers/db_provider.dart';
import 'package:zhuoluo/core/utils/app_clock.dart';

/// 偏好设置页（偏好设置组，2026-08-08）：
/// 默认清单 / 默认提醒提前量 / 全天任务默认提醒时刻 / 应用时区。
/// 独立文件，不再加大 profile_page（总览第 6 节拆分建议）。
class PreferencesPage extends ConsumerStatefulWidget {
  const PreferencesPage({super.key});

  @override
  ConsumerState<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends ConsumerState<PreferencesPage> {
  String _defaultListLabel = '加载中…';
  String _defaultRemindLabel = '加载中…';
  String _allDayAtLabel = '加载中…';
  String _timezoneLabel = '加载中…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsProvider);
    final db = ref.read(dbProvider);
    final lists = await db.getAllLists();
    final prefListId = await settings.getDefaultListId();
    final remindMin = await settings.getDefaultRemindMinutes();
    final allDayAt = await settings.getDefaultAllDayRemindAt();
    final timezone = await settings.getAppTimezone();

    String listLabel;
    if (prefListId == null) {
      listLabel = '跟随当前清单';
    } else {
      final match = lists.where((l) => l.id == prefListId).toList();
      listLabel = match.isEmpty ? '跟随当前清单' : match.first.name;
    }

    String remindLabel;
    if (remindMin == null) {
      remindLabel = '不预选';
    } else {
      remindLabel = _remindMinLabel(remindMin);
    }

    if (!mounted) return;
    setState(() {
      _defaultListLabel = listLabel;
      _defaultRemindLabel = remindLabel;
      _allDayAtLabel = _minutesToHm(allDayAt);
      _timezoneLabel = timezone ?? '跟随系统';
    });
  }

  static String _remindMinLabel(int m) => switch (m) {
    0 => '准时提醒',
    5 => '提前 5 分钟',
    10 => '提前 10 分钟',
    30 => '提前 30 分钟',
    60 => '提前 1 小时',
    120 => '提前 2 小时',
    1440 => '提前 1 天',
    2880 => '提前 2 天',
    _ => '提前 $m 分钟',
  };

  static String _minutesToHm(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('偏好设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: [
          const _SectionHeader('默认清单'),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('默认清单'),
            subtitle: Text(
              _defaultListLabel,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickDefaultList,
          ),
          const Divider(),
          const _SectionHeader('默认提醒'),
          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: const Text('默认提醒提前量'),
            subtitle: Text(
              _defaultRemindLabel,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickDefaultRemind,
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('全天任务默认提醒时刻'),
            subtitle: Text(
              _allDayAtLabel,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickAllDayAt,
          ),
          const Divider(),
          const _SectionHeader('时区'),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('应用时区'),
            subtitle: Text(
              '$_timezoneLabel（出差/旅行时任务仍按家乡时间显示和提醒）',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickTimezone,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 默认清单选择：跟随当前清单 / 收件箱 / 各清单（存储清单 id，空串 = 跟随）
  Future<void> _pickDefaultList() async {
    final settings = ref.read(settingsProvider);
    final db = ref.read(dbProvider);
    final lists = await db.getAllLists();
    final current = await settings.getDefaultListId();
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('跟随当前清单'),
              subtitle: const Text('任务页按当前选中的清单添加，日历添加进收件箱'),
              trailing: current == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, 'none'),
            ),
            for (final l in lists)
              ListTile(
                title: Text(l.name),
                subtitle: l.isDefault ? const Text('收件箱') : null,
                trailing: current == l.id ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(c, '${l.id}'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await settings.set(
      SettingsController.keyDefaultListId,
      choice == 'none' ? '' : choice,
    );
    if (mounted) await _load();
  }

  /// 默认提醒提前量：不预选 / 准时 / 预设档位。
  /// "不预选"用哨兵 -2 返回，与"取消"（null）区分。
  Future<void> _pickDefaultRemind() async {
    final settings = ref.read(settingsProvider);
    final current = await settings.getDefaultRemindMinutes();
    if (!mounted) return;
    const sentinelNone = -2;
    final options = <(int, String)>[
      (sentinelNone, '不预选'),
      (0, '准时提醒'),
      (5, '提前 5 分钟'),
      (10, '提前 10 分钟'),
      (30, '提前 30 分钟'),
      (60, '提前 1 小时'),
      (120, '提前 2 小时'),
      (1440, '提前 1 天'),
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              ListTile(
                title: Text(o.$2),
                trailing: current == (o.$1 == sentinelNone ? null : o.$1)
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(c, o.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return; // 取消
    await settings.set(
      SettingsController.keyDefaultRemindMinutes,
      choice == sentinelNone ? '' : '$choice',
    );
    if (mounted) await _load();
  }

  /// 全天任务默认提醒时刻（TimePicker，分钟数存储）
  Future<void> _pickAllDayAt() async {
    final settings = ref.read(settingsProvider);
    final current = await settings.getDefaultAllDayRemindAt();
    if (!mounted) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: '选择全天任务默认提醒时刻',
    );
    if (picked == null) return;
    await settings.set(
      SettingsController.keyDefaultAllDayRemindAt,
      '${picked.hour * 60 + picked.minute}',
    );
    if (mounted) await _load();
  }

  /// 应用时区：跟随系统 / 常用时区 / 搜索全部 IANA 时区。
  /// 切换后全量重排提醒（新时区口径）。
  Future<void> _pickTimezone() async {
    final settings = ref.read(settingsProvider);
    final picked = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (c) => _TimezonePickerSheet(current: AppClock.timezoneName),
    );
    if (picked == null) return; // 取消
    final name = picked.isEmpty ? null : picked;
    // 先切时钟（即时生效），再持久化；非法名时 AppClock 自动回落系统
    AppClock.setTimezone(name);
    await settings.set(SettingsController.keyAppTimezone, name ?? '');
    // 时区口径变化：全量重排 93 天窗口内所有提醒
    await ref.read(reminderSchedulerProvider).rescheduleAll();
    if (mounted) await _load();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
    ),
  );
}

/// 时区选择弹层：跟随系统 + 常用时区 + 搜索过滤全部 IANA 时区。
/// 返回值：空串 = 跟随系统；null = 取消。
class _TimezonePickerSheet extends StatefulWidget {
  const _TimezonePickerSheet({required this.current});

  final String? current;

  @override
  State<_TimezonePickerSheet> createState() => _TimezonePickerSheetState();
}

class _TimezonePickerSheetState extends State<_TimezonePickerSheet> {
  static const _commonZones = [
    'Asia/Shanghai',
    'Asia/Hong_Kong',
    'Asia/Taipei',
    'Asia/Tokyo',
    'Asia/Seoul',
    'Asia/Singapore',
    'Asia/Bangkok',
    'Asia/Jakarta',
    'Asia/Kolkata',
    'Asia/Dubai',
    'Europe/London',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Moscow',
    'America/New_York',
    'America/Chicago',
    'America/Los_Angeles',
    'America/Toronto',
    'Australia/Sydney',
    'Pacific/Auckland',
  ];

  String _query = '';
  List<String> _all = const [];

  @override
  void initState() {
    super.initState();
    // main 启动链已初始化；此处兜底（独立运行/测试环境）
    try {
      tzdata.initializeTimeZones();
    } catch (_) {}
    _all = tz.timeZoneDatabase.locations.keys.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final filtered = searching
        ? _all.where((z) => z.toLowerCase().contains(q)).toList()
        : _commonZones;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: false,
              decoration: InputDecoration(
                hintText: '搜索时区（如 Asia/Shanghai、Beijing）',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (!searching)
                  ListTile(
                    title: const Text('跟随系统时区'),
                    subtitle: const Text('与手机系统时区一致（默认）'),
                    trailing: widget.current == null
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, ''),
                  ),
                for (final z in filtered)
                  ListTile(
                    title: Text(z),
                    trailing: widget.current == z ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, z),
                  ),
                if (filtered.isEmpty)
                  const ListTile(
                    title: Text('未找到匹配的时区'),
                    enabled: false,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
