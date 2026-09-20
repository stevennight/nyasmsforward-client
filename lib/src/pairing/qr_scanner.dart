import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the camera and returns the text of the first QR code it reads (the pairing link shown by the Web console),
/// or null when the user goes back. The camera permission is only requested here, when the button is used.
Future<String?> scanQrCode(BuildContext context) => Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final text = b.rawValue;
      if (text != null && text.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(text);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描配对二维码')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '无法使用相机（${error.errorCode.name}）。可以在系统设置里允许相机权限，或者直接输入配对码。',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('对准 Web「设备与客户端」里生成的二维码', style: TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
            ),
          ),
        ],
      ),
    );
  }
}
