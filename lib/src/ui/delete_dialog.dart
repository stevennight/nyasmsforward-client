import 'package:flutter/material.dart';

/// Ask whether a delete should only use the server recycle bin or also request
/// deletion of the original SMS on the receiver phone.
Future<bool?> confirmDeleteWithPhoneOption(
  BuildContext context, {
  required String title,
  required String message,
}) {
  var deletePhone = false;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(alignment: Alignment.centerLeft, child: Text(message)),
            const SizedBox(height: 8),
            SwitchListTile(
              value: deletePhone,
              onChanged: (value) => setState(() => deletePhone = value),
              title: const Text('同步删除手机原短信'),
              subtitle: const Text(
                '关闭时只移入回收站，手机原短信保留不变；开启后手机在线时立即处理，离线后上线再处理。',
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, deletePhone),
            child: const Text('删除'),
          ),
        ],
      ),
    ),
  );
}
