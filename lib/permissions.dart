import 'package:permission_handler/permission_handler.dart';

class BLEPermissions {
  static Future<bool> requestPermissions() async {
    final List<Permission> permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ];

    final Map<Permission, PermissionStatus> statuses =
        await permissions.request();

    bool allGranted = true;
    for (final status in statuses.values) {
      if (status.isDenied || status.isPermanentlyDenied) {
        allGranted = false;
        break;
      }
    }

    return allGranted;
  }

  static Future<void> openAppSettings() async {
    openAppSettings();
  }
}