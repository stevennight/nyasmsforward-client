import 'package:flutter/services.dart';

/// HH:mm today, "昨天 HH:mm", otherwise M/D HH:mm (same as the web console).
String clock(int millis, {DateTime? now}) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  final n = now ?? DateTime.now();
  final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return hm;
  if (diff == 1) return '昨天 $hm';
  return '${d.month}/${d.day} $hm';
}

/// Copies [text] and returns whether it worked (the clipboard can be unavailable, e.g. on a locked-down desktop).
Future<bool> copyText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } on Object {
    return false;
  }
}
