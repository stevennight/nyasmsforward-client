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
              title: const Text('同时删除手机上的原短信'),
              subtitle: const Text(
                '接收端需要设为手机的默认短信应用才能删掉；手机离线时会在重新连上后处理。手机上删掉后无法恢复。',
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
