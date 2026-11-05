import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../game/engine.dart';
import '../game/rules.dart';

/// Host-only table settings with Arabic labels for TalkBack and VoiceOver.
///
/// «تفعيل مؤقت الدور» is off by default and turns the timer off completely.
/// «نقاط البداية» accepts any whole number from 1 to 99.
class TableSettingsForm extends StatefulWidget {
  const TableSettingsForm({
    super.key,
    required this.initial,
    required this.submitLabel,
    required this.onSubmit,
    this.leading = const [],
  });

  final TableSettings initial;
  final String submitLabel;

  /// Returns an Arabic error, or null when saved.
  final Future<String?> Function(TableSettings settings) onSubmit;
  final List<Widget> leading;

  @override
  State<TableSettingsForm> createState() => _TableSettingsFormState();
}

class _TableSettingsFormState extends State<TableSettingsForm> {
  late final TextEditingController _points;
  late final TextEditingController _timer;
  late bool _timerOn;
  late bool _teams;
  var _busy = false;
  String? _pointsError;
  String? _timerError;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _points = TextEditingController(text: '${initial.startPoints}');
    _timerOn = initial.timerEnabled;
    _timer = TextEditingController(
      text: initial.timerEnabled
          ? '${initial.timerSeconds}'
          : '$minTimerSeconds',
    );
    _teams = initial.teamsEnabled;
  }

  @override
  void dispose() {
    _points.dispose();
    _timer.dispose();
    super.dispose();
  }

  void _announce(String text) {
    final view = View.maybeOf(context);
    if (view != null) {
      SemanticsService.sendAnnouncement(view, text, TextDirection.rtl);
    }
  }

  Future<void> _submit() async {
    final parsed = parseTableSettings(
      startPointsText: _points.text,
      timerEnabled: _timerOn,
      timerText: _timer.text,
      teamsEnabled: _teams,
    );
    final settings = parsed.settings;
    if (settings == null) {
      setState(() {
        _pointsError = parsed.error == startPointsError ? parsed.error : null;
        _timerError = parsed.error == timerError ? parsed.error : null;
        _error = parsed.error;
      });
      _announce(parsed.error ?? '');
      return;
    }
    setState(() {
      _busy = true;
      _pointsError = null;
      _timerError = null;
      _error = null;
    });
    final error = await widget.onSubmit(settings);
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error != null) {
      _announce(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ...widget.leading,
        TextField(
          key: const Key('start_points'),
          controller: _points,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(2),
          ],
          textDirection: TextDirection.rtl,
          decoration: InputDecoration(
            labelText: 'نقاط البداية',
            helperText: 'اكتب رقماً من 1 إلى 99',
            errorText: _pointsError,
          ),
          onChanged: (_) {
            if (_pointsError != null) {
              setState(() => _pointsError = null);
            }
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('timer_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('تفعيل مؤقت الدور'),
          subtitle: Text(_timerOn ? 'المؤقت مفعّل' : 'المؤقت متوقف'),
          value: _timerOn,
          onChanged: (value) => setState(() {
            _timerOn = value;
            _timerError = null;
          }),
        ),
        if (_timerOn)
          TextField(
            key: const Key('timer_seconds'),
            controller: _timer,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            textDirection: TextDirection.rtl,
            decoration: InputDecoration(
              labelText: 'مدة مؤقت الدور بالثواني',
              helperText: '10 ثوانٍ على الأقل',
              errorText: _timerError,
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('فرق'),
          value: _teams,
          onChanged: (value) => setState(() => _teams = value),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFFB4AB)),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}

/// Opens the settings page for a waiting table. Host only.
class TableSettingsScreen extends StatelessWidget {
  const TableSettingsScreen({
    super.key,
    required this.initial,
    required this.onSave,
  });

  final TableSettings initial;
  final Future<String?> Function(TableSettings settings) onSave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إعدادات الطاولة')),
      body: TableSettingsForm(
        initial: initial,
        submitLabel: 'حفظ الإعدادات',
        onSubmit: (settings) async {
          final error = await onSave(settings);
          if (error == null && context.mounted) {
            Navigator.of(context).pop();
          }
          return error;
        },
      ),
    );
  }
}
